#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${PROJECT_DIR}/build"
DIST_DIR="${PROJECT_DIR}/dist"

rm -rf "${BUILD_DIR}" "${DIST_DIR}/iosdm.ipa" "${DIST_DIR}/iosdm-iPhone.ipa"
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

# 1. Universal (iPhone + iPad / iPadOS 27.2.1)
build_variant "Universal" "1,2" "${DIST_DIR}/iosdm.ipa"

# 2. Dedicated iPhone edition
build_variant "iPhone" "1" "${DIST_DIR}/iosdm-iPhone.ipa"

echo "==> 打包完成："
ls -lh "${DIST_DIR}/iosdm.ipa" "${DIST_DIR}/iosdm-iPhone.ipa"
