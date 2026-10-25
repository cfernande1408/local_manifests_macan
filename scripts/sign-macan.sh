#!/usr/bin/env bash
# Sign a LineageOS build with private release keys (target-files method,
# see https://wiki.lineageos.org/signing_builds).
#
# The APEX and APK lists are read from the build's own target_files
# (META/apexkeys.txt and META/apkcerts.txt), so nothing is hardcoded.
#
# Usage (from the source tree, after lunch):
#   m otatools target-files-package
#   bash sign-macan.sh
#
# Env overrides: KEYS, SUBJECT, DIST
set -euo pipefail

: "${OUT:?Run 'source build/envsetup.sh' and lunch first}"
TOP=${ANDROID_BUILD_TOP:?Run 'source build/envsetup.sh' and lunch first}
cd "$TOP"

KEYS=${KEYS:-$HOME/.android-certs}
SUBJECT=${SUBJECT:-'/C=ES/ST=Madrid/L=Madrid/O=cfernande1408/OU=LineageOS macan/CN=cfernande1408'}
DIST=${DIST:-$TOP/release}
export PATH="$TOP/out/host/linux-x86/bin:$PATH"

# Signing unpacks and rebuilds multi-GB images; /tmp is often a small tmpfs.
export TMPDIR=${TMPDIR_SIGN:-$TOP/out/tmp-sign}
rm -rf "$TMPDIR"
mkdir -p "$TMPDIR"
# The unpacked target_files dir is only a build leftover; free its space.
rm -rf "$OUT"/obj/PACKAGING/target_files_intermediates/*-target_files/
NEED_GB=${NEED_GB:-40}
FREE_GB=$(df -BG --output=avail "$TMPDIR" | tail -1 | tr -dc 0-9)
echo ">> Temp dir: $TMPDIR (${FREE_GB}G free)"
if [ "$FREE_GB" -lt "$NEED_GB" ]; then
  echo "Need at least ${NEED_GB}G free to sign. Free some space and retry."
  exit 1
fi

for t in sign_target_files_apks ota_from_target_files openssl unzip; do
  command -v "$t" >/dev/null || { echo "Missing $t (run: m otatools)"; exit 1; }
done

TF=$(ls -t "$OUT"/obj/PACKAGING/target_files_intermediates/*-target_files*.zip 2>/dev/null | head -1 || true)
[ -n "$TF" ] || { echo "No target_files zip (run: m target-files-package)"; exit 1; }
echo ">> target_files: $TF"

mkdir -p "$KEYS" "$DIST"
chmod 700 "$KEYS"

# make_key asks for a password once; an empty line means no password.
genkey() { # $1 = key path prefix, $2 = make_key script
  [ -e "$1.pk8" ] && return 0
  local log
  # make_key may exit non-zero even on success; judge by the files it leaves.
  log=$(printf '\n' | "$2" "$1" "$SUBJECT" 2>&1) || true
  if [ ! -e "$1.pk8" ] || [ ! -e "$1.x509.pem" ]; then
    echo "Failed to create $1. make_key said:"
    echo "$log"
    exit 1
  fi
}

echo ">> Base keys in $KEYS"
for k in bluetooth cyngn-app media networkstack nfc platform releasekey \
         sdk_sandbox shared testcert testkey verity; do
  genkey "$KEYS/$k" ./development/tools/make_key
done

# APEX keys must be RSA4096.
cp -f development/tools/make_key "$KEYS/make_key4096"
sed -i 's|2048|4096|g' "$KEYS/make_key4096"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
unzip -q -o "$TF" META/apexkeys.txt META/apkcerts.txt -d "$WORK"

ARGS=()
napex=0
echo ">> APEX keys"
while IFS= read -r line; do
  name=$(sed -n 's/^name="\([^"]*\)".*/\1/p' <<<"$line")
  [ -n "$name" ] || continue
  grep -q 'container_certificate="PRESIGNED"' <<<"$line" && continue
  base=${name%.apex}
  base=${base%.capex}
  genkey "$KEYS/$base" "$KEYS/make_key4096"
  [ -e "$KEYS/$base.pem" ] || \
    openssl pkcs8 -in "$KEYS/$base.pk8" -inform DER -nocrypt -out "$KEYS/$base.pem"
  ARGS+=(--extra_apks "$name=$KEYS/$base"
         --extra_apex_payload_key "$name=$KEYS/$base.pem")
  napex=$((napex + 1))
done < "$WORK/META/apexkeys.txt"
echo "   $napex APEX"

# -d already maps these build/make/target/product/security keys.
DEFAULTS=" testkey devkey media shared platform networkstack sdk_sandbox "
declare -A MAPPED=()
napk=0
echo ">> APKs with non-default certificates"
while IFS= read -r line; do
  apk=$(sed -n 's/^name="\([^"]*\)".*/\1/p' <<<"$line")
  cert=$(sed -n 's/.* certificate="\([^"]*\)".*/\1/p' <<<"$line")
  [ -n "$apk" ] && [ -n "$cert" ] || continue
  [ "$cert" = PRESIGNED ] && continue
  k=$(basename "$cert" .x509.pem)
  if [[ "$cert" == build/make/target/product/security/* ]]; then
    [[ "$DEFAULTS" == *" $k "* ]] && continue
    [ -n "${MAPPED[$k]:-}" ] && continue
    if [ -e "$KEYS/$k.pk8" ]; then
      # A key mapping (unlike --extra_apks) also rewrites the cert in
      # mac_permissions.xml, so apps keep their SELinux seinfo (e.g. nfc).
      ARGS+=(-k "build/make/target/product/security/$k=$KEYS/$k")
      MAPPED[$k]=1
      echo "   key map: $k"
      continue
    fi
  fi
  if [ -e "$KEYS/$k.pk8" ]; then key="$KEYS/$k"; else key="$KEYS/releasekey"; fi
  ARGS+=(--extra_apks "$apk=$key")
  napk=$((napk + 1))
done < "$WORK/META/apkcerts.txt"
echo "   $napk APK"

SIGNED_TF="$DIST/signed-target_files.zip"
echo ">> Signing target files (takes a while)"
sign_target_files_apks -o -d "$KEYS" "${ARGS[@]}" "$TF" "$SIGNED_TF"

# Take the name from the build's own version prop, not from
# whatever zips happen to be left in $OUT.
LV=$(unzip -p "$TF" PRODUCT/etc/build.prop 2>/dev/null | sed -n 's/^ro\.lineage\.version=//p' | head -1)
[ -n "$LV" ] || { echo "ro.lineage.version not found in $TF"; exit 1; }
VER="lineage-$LV"
OTA="$DIST/$VER-signed.zip"
echo ">> Building OTA package"
ota_from_target_files -k "$KEYS/releasekey" --block --backup=true "$SIGNED_TF" "$OTA"

echo ">> Extracting images for first install"
for img in boot init_boot dtbo vendor_boot recovery; do
  unzip -q -o -j "$SIGNED_TF" "IMAGES/$img.img" -d "$DIST"
done

rm -rf "$TMPDIR"

cd "$DIST"
sha256sum "$(basename "$OTA")" boot.img init_boot.img dtbo.img vendor_boot.img recovery.img > SHA256SUMS
echo ">> Done. Files in $DIST:"
cat SHA256SUMS
