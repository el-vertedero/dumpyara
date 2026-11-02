#!/usr/bin/env bash

# Add logging definition to make output clearer
## Info
LOGI() {
    echo -e "[\033[32mINFO\033[0m]: ${1}"
}

## Warning
LOGW() {
    echo -e "[\033[33mWARNING\033[0m]: ${1}"
}

## Error
LOGE() {
    echo -e "[\033[31mERROR\033[0m]: ${1}"
}

## Fatal
LOGF() {
    echo -e "[\033[41mFATAL\033[0m]: ${1}"
    exit 1
}

# Whether '$1' is an SWUpdate package: a 'newc' cpio archive whose first
# entry is 'sw-description'. VegaOS (Fire TV, Echo) firmware ships like this.
is_swupdate() {
    [[ -f "${1}" ]] || return 1
    [[ "$(head -c 6 "${1}")" == 07070[12] ]] || return 1
    [[ "$(dd if="${1}" bs=1 skip=110 count=15 2> /dev/null | LC_ALL=C tr '\0' '\n')" == "sw-description" ]]
}

# Print the filesystem ('squashfs' or 'erofs') of image '$1', fail otherwise
fs_type() {
    [[ -f "${1}" ]] || return 1
    case "$(od -A n -t x1 -N 4 "${1}" | tr -d ' \n')" in
        68737173|73717368) echo "squashfs"; return 0 ;;
    esac
    [[ "$(od -A n -t x1 -j 1024 -N 4 "${1}" 2> /dev/null | tr -d ' \n')" == "e2e1f5e0" ]] && echo "erofs"
}

# Print the value of key '$2' from 'os-release' file '$1' (without sourcing it)
os_release() {
    sed -n "s/^${2}=//p" "${1}" | head -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

# Get the current directory ready to be pushed to '${ORG}/${repo}' (branch
# '${branch}'): bail out if it's already there, create the repository and
# replace files too large for GitHub with compressed copies. Committing and
# pushing (through '${GITPUSH[@]}') is left to the caller.
prepare_push() {
    # Send the token as a header instead of embedding it in the URL: git drops
    # URL credentials when it thinks the remote redirected, then tries to prompt.
    GIT_AUTH_HEADER="Authorization: Basic $(printf 'x-access-token:%s' "$GIT_OAUTH_TOKEN" | base64 -w0)"
    GITPUSH=(git -c http.extraHeader="$GIT_AUTH_HEADER" push https://github.com/"$ORG"/"${repo,,}".git "$branch")
    curl --silent --fail "https://raw.githubusercontent.com/$ORG/$repo/$branch/all_files.txt" 2> /dev/null && LOGE "Firmware already dumped!" && exit 1
    git init
    git config pack.windowMemory  256m
    git config pack.packSizeLimit 512m
    git config pack.threads       1
    git config core.bigFileThreshold 64m
    git config http.postBuffer    524288000
    if [[ -z "$(git config --get user.email)" ]]; then
        git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
    fi
    if [[ -z "$(git config --get user.name)" ]]; then
        git config user.name "github-actions[bot]"
    fi
    curl -s -X POST -H "Authorization: token ${GIT_OAUTH_TOKEN}" -d '{ "name": "'"$repo"'" }' "https://api.github.com/orgs/${ORG}/repos" #create new repo
    # Empty topics would get the whole request rejected, so leave them out
    topics=$(printf '"%s",' "$manufacturer" "$platform" "$top_codename" | sed -e 's/"",//g' -e 's/,$//')
    curl -s -X PUT -H "Authorization: token ${GIT_OAUTH_TOKEN}" -H "Accept: application/vnd.github.mercy-preview+json" -d '{ "names": ['"$topics"']}' "https://api.github.com/repos/${ORG}/${repo}/topics"
    git remote add origin https://github.com/$ORG/"${repo,,}".git
    git checkout -b "$branch"
    find . -size +97M -printf '%P\n' -o -name "*sensetime*" -printf '%P\n' -o -name "*.lic" -printf '%P\n' >| .gitignore
    # Compress large files in parallel
    compress_file() {
        local file_path="$1"
        local max_size=$((99 * 1024 * 1024)) # 99MB

        if [ -f "$file_path" ]; then
            local compressed_file="${file_path}.zst"
            zstdmt -T2 -19 --long=27 "$file_path" -o "$compressed_file"
            if [ $(stat -c%s "$compressed_file") -le $max_size ]; then
                echo "$compressed_file"
            else
                rm -f "$compressed_file"
            fi
        fi
    }

    export -f compress_file

    # Process files in parallel and collect compressed filenames
    cat .gitignore | xargs -P 2 -I {} bash -c 'compress_file "{}"' > compressed_files.txt
    echo "fs_config_dirs" >> .gitignore
    echo "fs_config_files" >> .gitignore

    # Create extraction script
    cat > extract_files.sh << 'EOF'
#!/bin/bash

while IFS= read -r file; do
    unzstd "$file"
done < compressed_files.txt
EOF
    chmod +x extract_files.sh
}

# Announce the dump on the Telegram channel
send_telegram() {
    [[ -z "$TG_TOKEN" ]] && return

    CHAT_ID="@vertedero_de_dumps"
    commit_head=$(git log --format=format:%H | head -n 1)
    commit_link="https://github.com/$ORG/$repo/commit/$commit_head"
    echo -e "Sending telegram notification"

    TEXT=$(cat <<EOF
<b>Brand: $brand</b>
<b>Device: $codename</b>
<b>Version:</b> $release
<b>Fingerprint:</b> $fingerprint
<b>GitHub:</b>
<a href="$commit_link">Commit</a>
<a href="https://github.com/$ORG/$repo/tree/$branch/">$codename</a>
EOF
)

    curl -s "https://api.telegram.org/bot${TG_TOKEN}/sendmessage" --data "text=${TEXT}&chat_id=${CHAT_ID}&parse_mode=HTML&disable_web_page_preview=True" > /dev/null
}

[[ $# = 0 ]] && \
    LOGF "No input provided."

PWD="$(cd $(dirname ${BASH_SOURCE[0]}); pwd -P)"

# Create input & working directory if it does not exist
mkdir -p "${PWD}"/working

# GitHub token
if [[ -n $2 ]]; then
    GIT_OAUTH_TOKEN=$2
elif [[ -f ".githubtoken" ]]; then
    GIT_OAUTH_TOKEN=$(< .githubtoken)
else
    LOGW "GitHub token not found. Dumping just locally..."
fi

# Telegram token
if [[ -f ".tgtoken" ]]; then
    TG_TOKEN=$(< .tgtoken)
fi

# Check whether input is a string or a file
if echo "${1}" | grep -e '^\(https\?\|ftp\)://.*$' > /dev/null; then
    # Set 'URL' to appended string
    URL="${1}"

    # Google Drive needs special handling: filename isn't in the URL and
    # large files require a confirmation token. Delegate to 'gdown'.
    if [[ "${URL}" == *"drive.usercontent.google.com"* ]]; then
        # 'gdown' doesn't recognize this host, rewrite it to a regular Drive link
        GDRIVE_ID=$(echo "${URL}" | grep -oP '[?&]id=\K[^&]+')
        [[ -z "${GDRIVE_ID}" ]] && LOGF "Could not extract file ID from Google Drive link. Aborting."
        URL="https://drive.google.com/uc?id=${GDRIVE_ID}"
    fi

    if [[ "${URL}" == *"drive.google.com"* ]] || [[ "${URL}" == *"docs.google.com"* ]]; then
        LOGI "Google Drive link detected. Downloading via 'gdown'..."
        LOGI "Started downloading file from link... ($(date +%R:%S))"

        # 'gdown' picks the filename from Drive's metadata, so let it
        # download into an empty staging directory and pick the file up after.
        GDRIVE_STAGE="${PWD}/working/.gdrive"
        rm -rf "${GDRIVE_STAGE}"
        mkdir -p "${GDRIVE_STAGE}"

        ( cd "${GDRIVE_STAGE}" && uvx gdown "${URL}" ) || \
            LOGF "Failed to download file from Google Drive. Aborting."

        LOGI "Finished downloading file. ($(date +%R:%S))"

        # Locate the downloaded file and sanitize its name
        DOWNLOADED_FILE=$(find "${GDRIVE_STAGE}" -maxdepth 1 -type f | head -n 1)
        [[ -z "${DOWNLOADED_FILE}" ]] && LOGF "Could not locate file downloaded by 'gdown'."

        SAFE_FILENAME=$(basename "${DOWNLOADED_FILE}" | sed 's/%[0-9A-Fa-f][0-9A-Fa-f]/_/g' | inline-detox)
        DEST_PATH="${PWD}/working/${SAFE_FILENAME}"

        mv "${DOWNLOADED_FILE}" "${DEST_PATH}"
        rm -rf "${GDRIVE_STAGE}"

        # Set 'INPUT' variable for rest of script
        INPUT="${DEST_PATH}"
    else
        # Override '${URL}' with best possible mirror of it
        case "${URL}" in
            # For Xiaomi: replace '${URL}' with (one of) the fastest mirror
            *"d.miui.com"*)
                # Do not run this loop in case we're already using one of the reccomended mirrors
                if ! echo "${URL}" | rg -q 'cdnorg|bkt-sgp-miui-ota-update-alisgp'; then
                    # Set '${URL_ORIGINAL}' and '${FILE_PATH}' in case we might need to roll back
                    URL_ORIGINAL=$(echo "${URL}" | sed -E 's|(https://[^/]+).*|\1|')
                    FILE_PATH=$(echo "${URL#*d.miui.com/}" | sed 's/?.*//')

                    # Array of different possible mirrors
                    MIRRORS=(
                        "https://cdnorg.d.miui.com"
                        "https://bkt-sgp-miui-ota-update-alisgp.oss-ap-southeast-1.aliyuncs.com"
                        "https://bn.d.miui.com"
                        "${URL_ORIGINAL}"
                    )

                    # Check back and forth for the best available mirror
                    for URLS in "${MIRRORS[@]}"; do
                        # Change mirror's domain with one(s) from array
                        URL=${URLS}/${FILE_PATH}

                        # Be sure that the mirror is available. Once found, break the loop 
                        if [ "$(curl -I -sS "${URL}" | head -n1 | cut -d' ' -f2)" == "404" ]; then
                            LOGW "${URLS} is not available. Trying with other mirror(s)..."
                        else
                            LOGI "Found best available mirror."
                            break
                        fi
                    done
                fi
                ;;
                # For Pixeldrain: replace the link with a direct one
                *"pixeldrain.com/u"*)
                    LOGI "Replacing with best available mirror."
                    URL="https://pd.cybar.xyz/${URL##*/}"
                ;;
                *"pixeldrain.com/d"*)
                    LOGI "Replacing with direct download link."
                    URL="https://pixeldrain.com/api/filesystem/${URL##*/}"
                ;;
            esac

        # Sanitize file name and path
        FILENAME="$(basename "${URL%%[?#]*}")"
        SAFE_FILENAME=$(echo "${FILENAME}" | sed 's/%[0-9A-Fa-f][0-9A-Fa-f]/_/g' | inline-detox)
        DEST_PATH="${PWD}/working/${SAFE_FILENAME}"

        # Start downloading from 'aria2c' and, if failed, 'wget'
        LOGI "Started downloading file from link... ($(date +%R:%S))"

        if [[ "${URL}" == *"temp.sh/"* ]]; then
            # temp.sh serves a landing page on GET; the file itself requires a POST
            curl -fsSL -X POST -o "${DEST_PATH}" "${URL}" || \
                LOGF "Failed to download file from temp.sh (download limit reached?). Aborting."
        else
            aria2c -q -s16 -x16 --check-certificate=false -d "${PWD}/working" -o "${SAFE_FILENAME}" "${URL}" || {
                rm -fv "${DEST_PATH}"
                wget -q --no-check-certificate -O "${DEST_PATH}" "${URL}" || \
                    LOGF "Failed to download file. Aborting."
            }
        fi

        LOGI "Finished downloading file. ($(date +%R:%S))"

        # Bail out if the host handed us a web page instead of the file
        if [[ "$(file -b --mime-type "${DEST_PATH}")" == "text/html" ]]; then
            rm -f "${DEST_PATH}"
            LOGF "Downloaded file is an HTML page, not firmware. Is the link a direct download? Aborting."
        fi

        # Set 'INPUT' variable for rest of script
        INPUT="${DEST_PATH}"
    fi
else
    # Otherwise, check if it's a file or directory
    if [[ -e ${1} ]]; then
        INPUT=${1}
    else
        LOGF "Invalid input. Aborting."
    fi
fi

ORG=el-vertedero #your GitHub org name
EXTENSION=$(echo "${INPUT##*.}" | inline-detox)
UNZIP_DIR=$(basename "${INPUT/.$EXTENSION/}" | sed 's/%[0-9A-Fa-f][0-9A-Fa-f]/_/g' | inline-detox)
WORKING=${PWD}/working/${UNZIP_DIR}_

# Delete previously dumped project
if [[ -d "${WORKING}" ]]; then
    rm -rf "${WORKING}"
fi

# Copy over directory to 'WORKING'
if [[ -d "${INPUT}" ]]; then
    LOGI 'Directory detected. Copying...'
    cp -a "${INPUT}" "${WORKING}"
fi

# clone other repo's
if [[ -d "${PWD}/external/Firmware_extractor" ]]; then
    git -C "${PWD}"/external/Firmware_extractor pull --recurse-submodules --rebase
else
    LOGI "Cloning 'Fimrware_extractor' to 'external/'..."
    git clone -q --recurse-submodules https://github.com/R0rt1z2/Firmware_extractor "${PWD}"/external/Firmware_extractor
fi

# Retrive 'extract-ikconfig' from torvalds/linux
if ! [[ -f "${PWD}"/external/extract-ikconfig ]]; then
    curl -s -Lo "${PWD}"/external/extract-ikconfig https://raw.githubusercontent.com/torvalds/linux/refs/heads/master/scripts/extract-ikconfig
    chmod +x "${PWD}"/external/extract-ikconfig
fi

# Set path for tools
UNPACKBOOTIMG="${PWD}"/external/Firmware_extractor/tools/unpackbootimg
VMLINUX_TO_ELF="uvx -q --from git+https://github.com/marin-m/vmlinux-to-elf@master"
EXTRACT_IKCONFIG="${PWD}"/external/extract-ikconfig
FSCK_EROFS="${PWD}"/external/Firmware_extractor/tools/fsck.erofs

# VegaOS (newer Fire TV / Echo devices running Vega Linux instead of FireOS)
# ships SWUpdate packages: filesystem images, a FIT 'boot.img' and install
# scripts in a cpio archive. None of the Android handling below applies.
if is_swupdate "${INPUT}"; then
    LOGI "VegaOS (SWUpdate) package detected"
    INPUT=$(realpath "${INPUT}")
    mkdir -p "${WORKING}"
    cd "${WORKING}" || exit

    LOGI "Extracting package..."
    cpio -idu --no-absolute-filenames --quiet < "${INPUT}" || \
        LOGF "Failed to extract package. Aborting."
    for gz in *.gz; do
        [[ -f "${gz}" ]] && gunzip -f "${gz}"
    done
    rm -f sw-description.sig

    # Extract filesystem images: the rootfs goes to 'system-rootfs/', the
    # vendor one to 'vendor-rootfs/', anything else to a directory named after it
    FS_DIRS=()
    for image in *; do
        fstype=$(fs_type "${image}") || continue

        case "${image}" in
            *vendor*) dir="vendor-rootfs" ;;
            *rootfs*) dir="system-rootfs" ;;
            *) dir="${image%%.*}" ;;
        esac
        [[ -e "${dir}" ]] && dir="${image}-extracted"
        [[ "${dir}" == "system-rootfs" ]] && ROOTFS_IMAGE="${image}"

        LOGI "Extracting '${image}' (${fstype}) to '${dir}/'..."
        case "${fstype}" in
            squashfs) unsquashfs -no-xattrs -f -d "${dir}" "${image}" ;;
            erofs) ${FSCK_EROFS} --extract="${dir}" "${image}" ;;
        esac > /dev/null 2>&1 || LOGW "Errors while extracting '${image}', keeping whatever came out."

        # Without root some entries (e.g. device nodes) can't be created, so
        # only give up if nothing came out at all
        if [[ -z "$(ls -A "${dir}" 2> /dev/null)" ]]; then
            rm -rf "${dir}"
            [[ "${dir}" == "system-rootfs" ]] && LOGF "Failed to extract rootfs. Aborting."
            LOGE "Failed to extract '${image}'."
            continue
        fi

        # Make sure git can read everything
        chmod -R u+rwX "${dir}"
        rm -f "${image}"
        FS_DIRS+=("${dir}")
    done

    # Build information lives in the rootfs' 'os-release'. Skip absolute
    # symlinks, those would resolve against the host.
    OS_RELEASE=/dev/null
    for file in system-rootfs/etc/os-release system-rootfs/usr/lib/os-release; do
        if [[ -f "${file}" && "$(readlink "${file}")" != /* ]]; then
            OS_RELEASE="${file}"
            break
        fi
    done
    [[ "${OS_RELEASE}" == /dev/null ]] && LOGW "No 'os-release' found in rootfs."

    os_name=$(os_release "${OS_RELEASE}" NAME)
    os_version=$(os_release "${OS_RELEASE}" OS_VERSION)
    [[ -z ${os_version} ]] && os_version=$(os_release "${OS_RELEASE}" VERSION_ID)
    branch_code=$(os_release "${OS_RELEASE}" BRANCH_CODE)
    build_date=$(os_release "${OS_RELEASE}" BUILD_DATE)
    version_number=$(os_release "${OS_RELEASE}" VERSION_NUMBER)
    description=$(os_release "${OS_RELEASE}" BUILD_DESC)
    fingerprint=$(os_release "${OS_RELEASE}" BUILD_FINGERPRINT)

    # Codename comes from the rootfs image name ('rootfs-<codename>.*'),
    # falling back to the fingerprint
    codename=$(echo "${ROOTFS_IMAGE}" | sed -n 's/.*rootfs-\([^.]*\).*/\1/p')
    [[ -z ${codename} ]] && codename=$(echo "${fingerprint}" | cut -d : -f 1 | awk -F / '{ print $NF }')

    brand="Amazon"
    manufacturer="amazon"
    platform=""
    release="${os_version}"
    [[ -z ${description} ]] && description="${codename}-${version_number:-${os_version}}"
    branch=$(echo "$description" | tr ' ' '-')
    repo=$(echo "$brand"_"$codename"_dump | tr '[:upper:]' '[:lower:]' | tr -d '\r\n')
    top_codename=$(echo "$codename" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)

    # 'boot.img' is a FIT image: pull out everything it carries
    if [[ -f boot.img ]] && [[ "$(od -A n -t x1 -N 4 boot.img | tr -d ' \n')" == "d00dfeed" ]]; then
        if ! command -v dumpimage > /dev/null 2>&1; then
            LOGE "'dumpimage' not found (install 'u-boot-tools'), skipping 'boot.img'."
        else
            LOGI "Extracting 'boot.img' (FIT) content..."
            mkdir -p boot/dtb boot/dts
            dumpimage -l boot.img > boot/fit-info.txt 2>&1 || \
                LOGE "Failed to list 'boot.img' content."

            # Every image is listed as ' Image <index> (<name>)', then its 'Type:'
            while read -r index name type <&3; do
                dumpimage -T flat_dt -p "${index}" -o "boot/${name}" boot.img > /dev/null 2>&1 || {
                    LOGE "Failed to extract '${name}' from 'boot.img'."
                    continue
                }

                case "${type}" in
                    "Kernel Image"*)
                        if [[ ! -f ikconfig ]]; then
                            ${EXTRACT_IKCONFIG} "boot/${name}" > ikconfig 2> /dev/null || rm -f ikconfig
                        fi
                        ;;
                    "Flat Device Tree")
                        mv "boot/${name}" "boot/dtb/${name}.dtb"
                        dtc -q -I dtb -O dts -o "boot/dts/${name}.dts" "boot/dtb/${name}.dtb" || \
                            LOGE "Failed to decompile '${name}'."
                        ;;
                    "RAMDisk Image")
                        case "$(od -A n -t x1 -N 4 "boot/${name}" | tr -d ' \n')" in
                            1f8b*) unpack="gzip -dc" ;;
                            fd377a58) unpack="xz -dc" ;;
                            28b52ffd) unpack="zstd -dc" ;;
                            02214c18|04224d18) unpack="lz4 -dc" ;;
                            *) unpack="cat" ;;
                        esac
                        mkdir -p "boot/${name}-extracted"
                        { ${unpack} "boot/${name}" | (cd "boot/${name}-extracted" && cpio -idu --no-absolute-filenames --quiet); } > /dev/null 2>&1 || \
                            LOGW "Errors while extracting '${name}', keeping whatever came out."
                        rmdir "boot/${name}-extracted" 2> /dev/null
                        ;;
                esac
            done 3< <(awk '/^ *Image [0-9]+ \(/ { idx = $2; name = $3; gsub(/[()]/, "", name) }
                          /^ *Type:/ && idx != "" { sub(/^ *Type: */, ""); print idx, name, $0; idx = "" }' boot/fit-info.txt)

            rmdir boot/dtb boot/dts 2> /dev/null
        fi
    fi

    # Sort out what's left
    mkdir -p install-scripts firmware
    for file in *.sh; do
        [[ -f "${file}" ]] && mv "${file}" install-scripts/
    done
    for file in *.bin *.img; do
        [[ -f "${file}" ]] && mv "${file}" firmware/
    done
    rmdir install-scripts firmware 2> /dev/null

    LOGI "Generating 'all_files.txt'..."
    find . -type f ! -name all_files.txt \
         -printf '%P\n' | sort | grep -v ".git/" > ./all_files.txt

    printf "# %s\n- manufacturer: %s\n- codename: %s\n- os: %s\n- version: %s\n- build date: %s\n- fingerprint: %s\n- brand: %s\n- branch: %s\n- repo: %s\n" \
        "$description" "$manufacturer" "$codename" "$os_name $os_version${branch_code:+ ($branch_code)}" "$version_number" "$build_date" "$fingerprint" "$brand" "$branch" "$repo" > README.md
    cat README.md

    if [[ -z "${codename}" || -z "${fingerprint}" ]]; then
        LOGE "Incomplete dump: missing codename/fingerprint."
        LOGE "Skipping GitHub push and Telegram notification."
        exit 1
    fi

    if [[ -n $GIT_OAUTH_TOKEN ]]; then
        prepare_push
        # Extracted filesystems are the bulk of it, push them one by one
        git add --all
        [[ ${#FS_DIRS[@]} -gt 0 ]] && git reset -q HEAD -- "${FS_DIRS[@]}"
        git commit -asm "Add extras for ${description}" && "${GITPUSH[@]}"
        for dir in "${FS_DIRS[@]}"; do
            git add "${dir}"
            git commit -asm "Add ${dir} for ${description}" && "${GITPUSH[@]}"
        done
    else
        LOGI "Dump done locally."
        exit 1
    fi

    send_telegram
    exit 0
fi

# Extract input via 'Firmware_extractor'
if [[ ! -d "${INPUT}" ]]; then
    bash "$PWD"/external/Firmware_extractor/extractor.sh "${INPUT}" "${WORKING}" || LOGF "Extraction failed. Aborting."
fi

# Initialize images extraction
cd "${WORKING}" || exit

# Create an array of partitions that need to be extracted
PARTITIONS=(system systemex system_ext system_other vendor cust odm odm_ext oem factory 
    product modem xrom oppo_product opproduct reserve india my_preload my_odm my_stock
    my_operator my_country my_product my_company my_engineering my_heytap my_custom my_manifest my_carrier my_region 
    my_bigball my_version special_preload vendor_dlkm odm_dlkm system_dlkm mi_ext mi_product radio
    product_h preas preavs preload
)

# Extract the images
LOGI "Extracting partitions..."
for partition in "${PARTITIONS[@]}"; do
    # Proceed only if the image from 'PARTITIONS' array exists
    if [[ -f "${partition}".img ]]; then
        # Try EROFS first, then squashfs, falling back to '7z' as a catch-all.
        ${FSCK_EROFS} --extract="${partition}" "${partition}".img >> /dev/null 2>&1 || {
            if [[ "$(file -b "${partition}".img)" == *Squashfs* ]]; then
                # 'unsquashfs' reproduces symlink chains that newer '7z'
                # refuses as "dangerous" (and aborts on). '-no-xattrs' avoids a
                # non-zero exit when run without root (SELinux labels can't be
                # restored and aren't needed for dumping).
                unsquashfs -no-xattrs -f -d "${partition}" "${partition}".img >> /dev/null 2>&1 || {
                    LOGE "'${partition}' extraction via 'unsquashfs' failed."

                    # Only abort if we're at the first occourence
                    if [[ "${partition}" == "${PARTITIONS[0]}" ]]; then
                        LOGF "Aborting dumping considering it's a crucial partition."
                    fi
                }
            else
                # Try to extract file through '7z'
                7z -snld x "${partition}".img -y -o"${partition}"/ > /dev/null || {
                    LOGE "'${partition}' extraction via '7z' failed."

                    # Only abort if we're at the first occourence
                    if [[ "${partition}" == "${PARTITIONS[0]}" ]]; then
                        LOGF "Aborting dumping considering it's a crucial partition."
                    fi
                }
            fi
        }

        # Clean-up
        rm -f "${partition}".img
    fi
done

# Also extract 'fsg.mbn' from 'radio.img'
if [ -f "fsg.mbn" ]; then
    LOGI "Extracting 'fsg.mbn' via '7zz'..."
    mkdir "radio/fsg"

    # Thankfully, 'fsg.mbn' is a simple EXT2 partition
    7zz -snld x "fsg.mbn" -o"radio/fsg" > /dev/null

    # Remove 'fsg.mbn'
    rm -rf "fsg.mbn"
fi

# Extract and decompile device-tree blobs
for image in boot vendor_boot vendor_kernel_boot; do
    if [[ -f "${image}".img ]]; then
        # Create working directories
        mkdir -p "${image}/dtb" "${image}/dts"

        # Unpack image's content
        LOGI "Extracting '${image}' content..."
        ${UNPACKBOOTIMG} -i "${image}.img" -o "${image}/" > /dev/null || \
            LOGE "Extraction via 'unpackbootimg' unsuccessful."

        ## Retrive image's ramdisk, and extract it
        unlz4 "${image}"/"${image}".img-*ramdisk "${image}/ramdisk.lz4" >> /dev/null 2>&1
        7z -snld x "${image}/ramdisk.lz4" -o"${image}/ramdisk" >> /dev/null 2>&1  || \
            LOGI "Failed to extract ramdisk."

        ## Clean-up
        rm -rf "${image}/ramdisk.lz4"
        rm -rf "${image}/${image}".img-*ramdisk

        # Extract 'dtb' via 'extract-dtb'
        LOGI "Trying to extract device-tree(s) from '${image}'..." 
        uvx extract-dtb "${image}.img" -o "${image}/dtb" >> /dev/null 2>&1 || \
            LOGE "Failed to extract device-tree blobs."

        # Remove '00_kernel'
        rm -rf "${image}/dtb/00_kernel"

        # Decompile blobs to 'dts' via 'dtc'
        for dtb in $(find "${image}/dtb" -type f); do
            dtc -q -I dtb -O dts "${dtb}" >> "${image}/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')" || \
                LOGE "Failed to decompile device-tree blobs."
        done
    fi

    # If no device-tree were extracted or decompiled, delete the directories
    if ! ls -A ${image}/dtb >> /dev/null 2>&1; then
        rm -rf "${image}/dtb" "${image}/dts"
    fi
done

# Extract 'boot.img'-related content
if [[ -f boot.img ]]; then
    # Extract 'ikconfig'
    LOGI "Extracting 'ikconfig'..."
    ${EXTRACT_IKCONFIG} boot.img > ikconfig 2>/dev/null || {
        LOGW "No 'ikconfig' found in 'boot.img'"
        rm -f ikconfig
    }

    # Generate non-stack symbols
    LOGI "Generating 'boot.img-kallsyms'..."
    ${VMLINUX_TO_ELF} kallsyms-finder boot.img >> /dev/null 2>&1 > boot/boot.img-kallsyms || \
        LOGE "Failed to generate 'boot.img-kallsyms'"

    # Generate analyzable '.elf'
    LOGI "Extracting 'boot.img-elf'..."
    ${VMLINUX_TO_ELF} vmlinux-to-elf boot.img boot/boot.img-elf >> /dev/null 2>&1 > /dev/null ||
        LOGE "Failed to generate 'boot.img-elf'"
fi

# Extract 'dtbo.img' separately
if [[ -f dtbo.img ]]; then
    # Create working directories
    mkdir -p "dtbo/dts"

    # Extract 'dtb' via 'extract-dtb'
    LOGI "Trying to extract device-tree(s) from 'dtbo'..." 
    uvx extract-dtb "dtbo.img" -o "dtbo/"  >> /dev/null 2>&1 || \
        LOGE "Failed to extract device-tree blobs."

    # Remove '00_kernel'
    rm -rf "dtbo/00_kernel"

    # Decompile blobs to 'dts' via 'dtc'
    for dtb in $(find "dtbo" -type f -name "*.dtb"); do
        dtc -q -I dtb -O dts "${dtb}" >> "dtbo/dts/$(basename "${dtb}" | sed 's/\.dtb/.dts/')" || \
            LOGE "Failed to decompile device-tree blobs."
    done
fi

# Generate 'board-info.txt'
LOGI "Generating 'board-info.txt'..."

## Generic
if [ -f vendor/build.prop ]; then
    strings ./vendor/build.prop | grep "ro.vendor.build.date.utc" | sed "s|ro.vendor.build.date.utc|require version-vendor|g" >> ./board-info.txt
fi

## Qualcomm-specific
if [[ $(find . -wholename "modem") ]] && [[ $(find . -wholename "*./tz*") ]]; then
    find ./modem -type f -exec strings {} \; | rg "QC_IMAGE_VERSION_STRING=MPSS." | sed "s|QC_IMAGE_VERSION_STRING=MPSS.||g" | cut -c 4- | sed -e 's/^/require version-baseband=/' >> board-info.txt
    find ./tz* -type f -exec strings {} \; | rg "QC_IMAGE_VERSION_STRING" | sed "s|QC_IMAGE_VERSION_STRING|require version-trustzone|g" >> board-info.txt
fi

## Sort 'board-info.txt' content
if [ -f board-info.txt ]; then
    sort -u -o board-info.txt board-info.txt
fi

# Generate 'all_files.txt'
LOGI "Generating 'all_files.txt'..."
find . -type f ! -name all_files.txt \
     -printf '%P\n' | sort | grep -v ".git/" > ./all_files.txt

# 'flavor' property (e.g. caiman-user)
flavor=$(rg -m1 -INoP --no-messages "(?<=^ro.build.flavor=).*" {vendor,system,system/system}/build.prop | head -n 1)
[[ -z ${flavor} ]] && flavor=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.flavor=).*" vendor/build*.prop | head -n 1)
[[ -z ${flavor} ]] && flavor=$(rg -m1 -INoP --no-messages "(?<=^ro.build.flavor=).*" {vendor,system,system/system}/build*.prop | head -n 1)
[[ -z ${flavor} ]] && flavor=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.flavor=).*" {system,system/system}/build*.prop | head -n 1)
[[ -z ${flavor} ]] && flavor=$(rg -m1 -INoP --no-messages "(?<=^ro.build.type=).*" {system,system/system}/build*.prop | head -n 1)

# 'release' property (e.g. 15)
release=$(rg -m1 -INoP --no-messages "(?<=^ro.build.version.release=).*" {my_manifest,vendor,system,system/system}/build*.prop | head -n 1)
[[ -z ${release} ]] && release=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.version.release=).*" vendor/build*.prop | head -n 1)
[[ -z ${release} ]] && release=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.version.release=).*" {system,system/system}/build*.prop | head -n 1)
release=$(echo "$release" | head -n 1)

# 'id' property (e.g. AP4A.241205.013)
id=$(rg -m1 -INoP --no-messages "(?<=^ro.build.id=).*" my_manifest/build*.prop | head -n 1)
[[ -z ${id} ]] && id=$(rg -m1 -INoP --no-messages "(?<=^ro.build.id=).*" system/system/build_default.prop | head -n 1)
[[ -z ${id} ]] && id=$(rg -m1 -INoP --no-messages "(?<=^ro.build.id=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${id} ]] && id=$(rg -m1 -INoP --no-messages "(?<=^ro.build.id=).*" {vendor,system,system/system}/build*.prop | head -n 1)
[[ -z ${id} ]] && id=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.id=).*" vendor/build*.prop | head -n 1)
[[ -z ${id} ]] && id=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.id=).*" {system,system/system}/build*.prop | head -n 1)
id=$(echo "$id" | head -n 1)

# 'incremental' property (e.g. 12621605)
incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.build.version.incremental=).*" my_manifest/build*.prop | head -n 1)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.build.version.incremental=).*" system/system/build_default.prop | head -n 1)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.build.version.incremental=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.build.version.incremental=).*" {vendor,system,system/system}/build*.prop | head -n 1)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.version.incremental=).*" my_manifest/build*.prop | head -n 1)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.version.incremental=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.version.incremental=).*" vendor/build*.prop | head -n 1)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.version.incremental=).*" {system,system/system}/build*.prop | head -n 1)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.build.version.incremental=).*" my_product/build*.prop | head -n 1)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.version.incremental=).*" my_product/build*.prop | head -n 1)
[[ -z ${incremental} ]] && incremental=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.version.incremental=).*" my_product/build*.prop | head -n 1)
incremental=$(echo "$incremental" | head -n 1)

# 'tags' property (e.g. release-keys)
tags=$(rg -m1 -INoP --no-messages "(?<=^ro.build.tags=).*" {vendor,system,system/system}/build*.prop | head -n 1)
[[ -z ${tags} ]] && tags=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.tags=).*" vendor/build*.prop | head -n 1)
[[ -z ${tags} ]] && tags=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.tags=).*" {system,system/system}/build*.prop | head -n 1)
tags=$(echo "$tags" | head -n 1)

# 'platform' property (e.g. zumapro)
platform=$(rg -m1 -INoP --no-messages "(?<=^ro.board.platform=).*" {vendor,system,system/system}/build*.prop | head -n 1)
[[ -z ${platform} ]] && platform=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.board.platform=).*" vendor/build*.prop | head -n 1)
[[ -z ${platform} ]] && platform=$(rg -m1 -INoP --no-messages "(?<=^ro.system.board.platform=).*" {system,system/system}/build*.prop | head -n 1)
platform=$(echo "$platform" | head -n 1)

# 'manufacturer' property (e.g. google)
manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.manufacturer=).*" odm/etc/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" odm/etc/fingerprint/build.default.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" my_product/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" my_manifest/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" system/system/build_default.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" {vendor,system,system/system}/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand.sub=).*" my_product/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand.sub=).*" system/system/euclid/my_product/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.product.manufacturer=).*" vendor/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.manufacturer=).*" my_manifest/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.manufacturer=).*" system/system/build_default.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.manufacturer=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.manufacturer=).*" vendor/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.system.product.manufacturer=).*" {system,system/system}/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.system.manufacturer=).*" {system,system/system}/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.manufacturer=).*" my_manifest/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.manufacturer=).*" system/system/build_default.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.manufacturer=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.manufacturer=).*" vendor/odm/etc/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" {oppo_product,my_product}/build*.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.manufacturer=).*" vendor/euclid/*/build.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.system.product.manufacturer=).*" vendor/euclid/*/build.prop | head -n 1)
[[ -z ${manufacturer} ]] && manufacturer=$(rg -m1 -INoP --no-messages "(?<=^ro.product.product.manufacturer=).*" vendor/euclid/product/build*.prop | head -n 1)
manufacturer=$(echo "$manufacturer" | head -n 1)

# 'fingerprint' property (e.g. google/caiman/caiman:15/AP4A.241205.013/12621605:user/release-keys)
fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.odm.build.fingerprint=).*" odm/etc/*build*.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.fingerprint=).*" my_manifest/build*.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.fingerprint=).*" system/system/build_default.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.fingerprint=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.fingerprint=).*" odm/etc/fingerprint/build.default.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.fingerprint=).*" vendor/build*.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.build.fingerprint=).*" my_manifest/build*.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.build.fingerprint=).*" system/system/build_default.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.build.fingerprint=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.build.fingerprint=).*"  {system,system/system}/build*.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.product.build.fingerprint=).*" product/build*.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.fingerprint=).*" {system,system/system}/build*.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.build.fingerprint=).*" my_product/build.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.fingerprint=).*" my_product/build.prop | head -n 1)
[[ -z ${fingerprint} ]] && fingerprint=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.fingerprint=).*" my_product/build.prop | head -n 1)
fingerprint=$(echo "$fingerprint" | head -n 1)

# 'codename' property (e.g. caiman)
codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.device=).*" odm/etc/build*.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.device=).*" system/system/build_default.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.device=).*" odm/etc/fingerprint/build.default.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.device=).*" my_manifest/build*.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.device=).*" system/system/build_default.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.device=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.device=).*" system/system/build_default.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.device=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.product.device=).*" system/system/build_default.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.product.device=).*" vendor/build*.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.device=).*" vendor/build*.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.device=).*" {vendor,system,system/system}/build*.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.product.device.oem=).*" odm/build.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.product.device.oem=).*" vendor/euclid/odm/build.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.device=).*" my_manifest/build*.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.system.device=).*" {system,system/system}/build*.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.system.device=).*" vendor/euclid/*/build.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.product.device=).*" vendor/euclid/*/build.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.product.device=).*" system/system/build_default.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.product.model=).*" vendor/euclid/*/build.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.device=).*" {oppo_product,my_product}/build*.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.product.device=).*" oppo_product/build*.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.system.device=).*" my_product/build*.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.device=).*" my_product/build*.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.build.fota.version=).*" {system,system/system}/build*.prop | cut -d - -f1 | head -n 1)
[[ -z ${codename} ]] && codename=$(rg -m1 -INoP --no-messages "(?<=^ro.build.product=).*" {vendor,system,system/system}/build*.prop | head -n 1)
[[ -z ${codename} ]] && codename=$(echo "$fingerprint" | cut -d / -f3 | cut -d : -f1)

# 'brand' property (e.g. google)
brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.brand=).*" odm/etc/"${codename}"_build.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.brand=).*" odm/etc/build*.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.brand=).*" system/system/build_default.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand=).*" odm/etc/fingerprint/build.default.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand=).*" my_product/build*.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand=).*" system/system/build_default.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand=).*" {vendor,system,system/system}/build*.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand.sub=).*" my_product/build*.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand.sub=).*" system/system/euclid/my_product/build*.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.brand=).*" my_manifest/build*.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.brand=).*" system/system/build_default.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.brand=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.vendor.brand=).*" vendor/build*.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.product.brand=).*" vendor/build*.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.system.brand=).*" {system,system/system}/build*.prop | head -n 1)
[[ -z ${brand} || ${brand} == "OPPO" ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.system.brand=).*" vendor/euclid/*/build.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.product.brand=).*" vendor/euclid/product/build*.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.brand=).*" my_manifest/build*.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.brand=).*" vendor/euclid/my_manifest/build.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.odm.brand=).*" vendor/odm/etc/build*.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(rg -m1 -INoP --no-messages "(?<=^ro.product.brand=).*" {oppo_product,my_product}/build*.prop | head -n 1)
[[ -z ${brand} ]] && brand=$(echo "$fingerprint" | cut -d / -f1)
[[ -z ${brand} ]] && brand="$manufacturer"

# 'description' property (e.g. caiman-user 15 AP4A.241205.013 12621605 release-keys)
description=$(rg -m1 -INoP --no-messages "(?<=^ro.build.description=).*" {system,system/system}/build.prop | head -n 1)
[[ -z ${description} ]] && description=$(rg -m1 -INoP --no-messages "(?<=^ro.build.description=).*" {system,system/system}/build*.prop | head -n 1)
[[ -z ${description} ]] && description=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.description=).*" vendor/build.prop | head -n 1)
[[ -z ${description} ]] && description=$(rg -m1 -INoP --no-messages "(?<=^ro.vendor.build.description=).*" vendor/build*.prop | head -n 1)
[[ -z ${description} ]] && description=$(rg -m1 -INoP --no-messages "(?<=^ro.product.build.description=).*" product/build.prop | head -n 1)
[[ -z ${description} ]] && description=$(rg -m1 -INoP --no-messages "(?<=^ro.product.build.description=).*" product/build*.prop | head -n 1)
[[ -z ${description} ]] && description=$(rg -m1 -INoP --no-messages "(?<=^ro.system.build.description=).*" {system,system/system}/build*.prop | head -n 1)
[[ -z ${description} ]] && description="$flavor $release $id $incremental $tags"

## Generate dummy device tree
#mkdir -p "${WORKING}/aosp-device-tree"
#LOGI "Generating dummy device tree..."
#uvx aospdtgen . --output "${WORKING}/aosp-device-tree" >> /dev/null 2>&1 || \
#    LOGE "Failed to generate AOSP device tree" && rm -rf "${WORKING}/aosp-device-tree"

is_ab=$(grep -oP "(?<=^ro.build.ab_update=).*" -hs {system,system/system,vendor}/build*.prop | head -n 1)
[[ -z "${is_ab}" ]] && is_ab="false"
branch=$(echo "$description" | tr ' ' '-')
repo=$(echo "$brand"_"$codename"_dump | tr '[:upper:]' '[:lower:]' | tr -d '\r\n')
platform=$(echo "$platform" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
top_codename=$(echo "$codename" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
manufacturer=$(echo "$manufacturer" | tr '[:upper:]' '[:lower:]' | tr -dc '[:print:]' | tr '_' '-' | cut -c 1-35)
printf "# %s\n- manufacturer: %s\n- platform: %s\n- codename: %s\n- flavor: %s\n- release: %s\n- id: %s\n- incremental: %s\n- tags: %s\n- fingerprint: %s\n- is_ab: %s\n- brand: %s\n- branch: %s\n- repo: %s\n" "$description" "$manufacturer" "$platform" "$codename" "$flavor" "$release" "$id" "$incremental" "$tags" "$fingerprint" "$is_ab" "$brand" "$branch" "$repo" > "${WORKING}"/README.md
cat "${WORKING}"/README.md

# Bail out if the dump is incomplete (no point pushing an empty repo
# or spamming Telegram with a blank notification).
if [[ -z "${codename}" || -z "${fingerprint}" || -z "${brand}" ]]; then
    LOGE "Incomplete dump: missing codename/brand/fingerprint."
    LOGE "Skipping GitHub push and Telegram notification."
    exit 1
fi

if [[ -n $GIT_OAUTH_TOKEN ]]; then
    prepare_push
    git add --all
    git reset HEAD -- system/ system_ext/ vendor/ product/ odm/ my_*/
    git commit -asm "Add extras for ${description}" && "${GITPUSH[@]}"
    git add system/system/app/ || git add system/app/
    git commit -asm "Add system app for ${description}" && "${GITPUSH[@]}"
    git add system/system/priv-app/ || git add system/priv-app/
    git commit -asm "Add system priv-app for ${description}" && "${GITPUSH[@]}"
    git add system/vendor
    git commit -asm "Add system/vendor for ${description}" && "${GITPUSH[@]}"
    git add system/
    git commit -asm "Add system for ${description}" && "${GITPUSH[@]}"
    git add system_ext/app/
    git commit -asm "Add system_ext app for ${description}" && "${GITPUSH[@]}"
    git add system_ext/priv-app/
    git commit -asm "Add system_ext priv-app for ${description}" && "${GITPUSH[@]}"
    git add system_ext/
    git commit -asm "Add system_ext for ${description}" && "${GITPUSH[@]}"
    git add product/app/
    git commit -asm "Add product app for ${description}" && "${GITPUSH[@]}"
    git add product/priv-app/
    git commit -asm "Add product priv-app for ${description}" && "${GITPUSH[@]}"
    git add product/
    git commit -asm "Add product for ${description}" && "${GITPUSH[@]}"
    git add vendor/
    git commit -asm "Add vendor for ${description}" && "${GITPUSH[@]}"
    git add odm/
    git commit -asm "Add odm for ${description}" && "${GITPUSH[@]}"
    if ls -d my_*/ >/dev/null 2>&1; then
        for oplus_dir in my_*/; do
            git add "${oplus_dir}"
            git commit -asm "Add ${oplus_dir} for ${description}" && "${GITPUSH[@]}"
        done
    fi
else
    LOGI "Dump done locally."
    exit 1
fi

# Telegram channel
send_telegram
