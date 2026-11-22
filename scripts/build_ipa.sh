#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
DIST_DIR="${PROJECT_DIR}/dist"
VERSION_STR="${IOSDM_VERSION:-1.0}"
RELEASE_TAG="v${VERSION_STR}"

rm -rf "${BUILD_DIR}" "${DIST_DIR}/iosdm.ipa" "${DIST_DIR}/iosdm-iPhone.ipa" "${DIST_DIR}/version.json"
mkdir -p "${DIST_DIR}"

build_variant() {
  local variant_name="$1"
  local device_family="$2"
  local output_ipa="$3"
  local derived="${BUILD_DIR}/DerivedData-${variant_name}"
  local payload_root="${BUILD_DIR}/stage-${variant_name}"
  local payload_dir="${payload_root}/Payload"

  echo "==> 编译 iosdm [${variant_name}] (TARGETED_DEVICE_FAMILY=${device_family}, Release, iphoneos, arm64, 无签名)..."
  xcodebuild \
    -project "${PROJECT_DIR}/iosdm.xcodeproj" \
    -scheme iosdm \
    -configuration Release \
    -sdk iphoneos \
    -destination 'generic/platform=iOS' \
    -derivedDataPath "${derived}" \
    TARGETED_DEVICE_FAMILY="${device_family}" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    AD_HOC_CODE_SIGNING_ALLOWED=NO \
    clean build

  local app_path="${derived}/Build/Products/Release-iphoneos/iosdm.app"
  if [ ! -d "${app_path}" ]; then
    echo "错误：未找到编译产物 ${app_path}" >&2
    exit 1
  fi

  echo "==> 封装 ${output_ipa}..."
  rm -rf "${payload_root}"
  mkdir -p "${payload_dir}"
  cp -R "${app_path}" "${payload_dir}/iosdm.app"

  (
    cd "${payload_root}"
    zip -qry "${output_ipa}" Payload
  )
}

# 1. Universal (iPhone + iPad, iOS/iPadOS 15.0 ~ 27.2.1)
build_variant "Universal" "1,2" "${DIST_DIR}/iosdm.ipa"

# 2. Dedicated iPhone edition (iOS 15.0+)
build_variant "iPhone" "1" "${DIST_DIR}/iosdm-iPhone.ipa"

# 3. Generate lightweight version.json manifest for manual update checks
cat > "${DIST_DIR}/version.json" <<EOF
{
  "version": "${VERSION_STR}",
  "build": 1,
  "notes": "iosdm v${VERSION_STR}：精简轻量版，支持 iOS/iPadOS 15.0+、多线程断点续传、海外网盘解析、自动/手动代理分流与一键保存到「文件」App。",
  "releaseURL": "https://github.com/amiamii1983/iosdm/releases/tag/${RELEASE_TAG}",
  "universalIPAURL": "https://github.com/amiamii1983/iosdm/releases/download/${RELEASE_TAG}/iosdm.ipa",
  "iPhoneIPAURL": "https://github.com/amiamii1983/iosdm/releases/download/${RELEASE_TAG}/iosdm-iPhone.ipa"
}
EOF

echo "==> 打包完成："
ls -lh "${DIST_DIR}/iosdm.ipa" "${DIST_DIR}/iosdm-iPhone.ipa" "${DIST_DIR}/version.json"
