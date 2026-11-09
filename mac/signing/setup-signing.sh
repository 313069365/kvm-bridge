#!/bin/sh
# 一次性配置：创建固定签名的代码签名身份。
# 之后每次重新编译都用同一个证书签名，macOS 的「辅助功能」授权就不会失效。
set -e
cd "$(dirname "$0")"

KC="$HOME/Library/Keychains/kvm-signing.keychain-db"
# 本机专用钥匙串密码，可用环境变量覆盖；默认值仅为脚本示例，非任何外部凭据。
PASS="${KVM_SIGN_PASS:-kvm123}"
NAME="KVM Bridge Dev"

# 新机器上首次运行时自动生成自签名身份；已有文件则复用，
# 这样同一台机器每次编译都用同一个证书，辅助功能授权不会失效。
# 生成的私钥是本机专用，已被 .gitignore 排除，请勿提交到仓库。
if [ ! -f key.pem ] || [ ! -f cert.pem ]; then
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout key.pem -out cert.pem -config csr.cnf >/dev/null 2>&1
    chmod 600 key.pem
    echo "generated: key.pem / cert.pem"
fi

openssl pkcs12 -export -inkey key.pem -in cert.pem -out id.p12 \
    -passout pass:"$PASS" -name "$NAME" >/dev/null 2>&1

if [ -f "$KC" ]; then
    security delete-keychain "$KC" >/dev/null 2>&1 || true
fi

security create-keychain -p "$PASS" "$KC"
security set-keychain-settings -lut 21600 "$KC"
security unlock-keychain -p "$PASS" "$KC"
security import id.p12 -k "$KC" -P "$PASS" -T /usr/bin/codesign -A >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASS" "$KC" >/dev/null

# 把签名钥匙串加入搜索列表（保留原有条目）
CURRENT=$(security list-keychains -d user | tr -d ' "')
security list-keychains -d user -s $CURRENT "$KC"

echo "identities:"
security find-identity -v -p codesigning "$KC"
