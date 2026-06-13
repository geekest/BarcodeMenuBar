#!/bin/bash

set -e

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${YELLOW}========================================${NC}"
echo -e "${YELLOW}  条形码菜单栏 - 自动构建脚本${NC}"
echo -e "${YELLOW}========================================${NC}"

# 获取脚本所在目录
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_NAME="BarcodeMenuBar"
BUILD_DIR="${SCRIPT_DIR}/.build"
RELEASE_DIR="${BUILD_DIR}/release"
APP_NAME="${PROJECT_NAME}"
APP_PATH="${RELEASE_DIR}/${APP_NAME}.app"
DMG_NAME="${PROJECT_NAME}.dmg"
DMG_PATH="${RELEASE_DIR}/${DMG_NAME}"
TEMP_DMG_DIR="${BUILD_DIR}/dmg_temp"

# 清理旧的构建
echo -e "${YELLOW}📦 清理旧的构建文件...${NC}"
rm -rf "${APP_PATH}" "${DMG_PATH}" "${TEMP_DMG_DIR}"
mkdir -p "${RELEASE_DIR}"

# 步骤 1: 构建项目
echo -e "${YELLOW}📝 编译项目...${NC}"
cd "${SCRIPT_DIR}"

# 获取编译输出路径
SWIFT_BUILD_PATH=$(swift build -c release --show-bin-path 2>/dev/null)
if [ -z "$SWIFT_BUILD_PATH" ]; then
    echo -e "${RED}❌ 获取构建路径失败${NC}"
    exit 1
fi

EXECUTABLE_PATH="${SWIFT_BUILD_PATH}/${PROJECT_NAME}"

# 执行构建
swift build -c release 2>&1 | grep -E "(error:|warning:|Build complete)" || true

if [ ! -f "${EXECUTABLE_PATH}" ]; then
    echo -e "${RED}❌ 找不到编译的可执行文件：${EXECUTABLE_PATH}${NC}"
    exit 1
fi

echo -e "${GREEN}✅ 编译成功${NC}"

# 步骤 2: 创建 .app 包结构
echo -e "${YELLOW}🏗️  创建应用包...${NC}"
APP_CONTENTS="${APP_PATH}/Contents"
APP_MACOS="${APP_CONTENTS}/MacOS"
APP_RESOURCES="${APP_CONTENTS}/Resources"

mkdir -p "${APP_MACOS}"
mkdir -p "${APP_RESOURCES}"

# 复制可执行文件
cp "${EXECUTABLE_PATH}" "${APP_MACOS}/${PROJECT_NAME}"
chmod +x "${APP_MACOS}/${PROJECT_NAME}"

# 复制 Info.plist
if [ -f "${SCRIPT_DIR}/Info.plist" ]; then
    cp "${SCRIPT_DIR}/Info.plist" "${APP_CONTENTS}/Info.plist"
    echo -e "${GREEN}✅ Info.plist 已复制${NC}"
else
    echo -e "${RED}❌ 找不到 Info.plist${NC}"
    exit 1
fi

echo -e "${GREEN}✅ 应用包创建完成${NC}"

# 步骤 3: 生成 DMG 文件
echo -e "${YELLOW}📀 生成 DMG 文件...${NC}"

# 创建临时目录
mkdir -p "${TEMP_DMG_DIR}"
cp -r "${APP_PATH}" "${TEMP_DMG_DIR}/"

# 创建 DMG
hdiutil create -volname "${PROJECT_NAME}" \
    -srcfolder "${TEMP_DMG_DIR}" \
    -ov -format UDZO \
    "${DMG_PATH}" > /dev/null 2>&1

# 清理临时目录
rm -rf "${TEMP_DMG_DIR}"

if [ -f "${DMG_PATH}" ]; then
    echo -e "${GREEN}✅ DMG 文件生成成功${NC}"
else
    echo -e "${RED}❌ DMG 生成失败${NC}"
    exit 1
fi

# 输出信息
echo ""
echo -e "${YELLOW}========================================${NC}"
echo -e "${GREEN}🎉 构建完成！${NC}"
echo -e "${YELLOW}========================================${NC}"
echo ""
echo -e "📱 应用包位置："
echo -e "   ${GREEN}${APP_PATH}${NC}"
echo ""
echo -e "📀 DMG 文件位置："
echo -e "   ${GREEN}${DMG_PATH}${NC}"
echo ""
echo -e "📊 文件大小："
du -h "${APP_PATH}" | awk '{print "   " $1}'
du -h "${DMG_PATH}" | awk '{print "   " $1}'
echo ""
echo -e "${YELLOW}可以直接运行：${NC}"
echo -e "   ${GREEN}open '${APP_PATH}'${NC}"
echo ""
echo -e "${YELLOW}或者分享 DMG 文件给他人${NC}"
echo -e "${YELLOW}========================================${NC}"
