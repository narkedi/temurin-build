#!/bin/sh
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
################################################################################

# This script examines the given SBOM metadata file, and then builds the exact same binary
# and then compares with the Temurin JDK for the same build version, or the optionally supplied TARBALL_URL.

set -e

[ $# -lt 1 ] && echo "Usage: $0 SBOM_URL TARBALL_URL" && exit 1
SBOM_URL=$1
TARBALL_URL=$2
ANT_VERSION=1.10.5
ANT_CONTRIB_VERSION=1.0b3

installPrereqs() {
  if test -r /etc/redhat-release; then
    yum install -y gcc gcc-c++ make autoconf unzip zip alsa-lib-devel cups-devel libXtst-devel libXt-devel libXrender-devel libXrandr-devel libXi-devel
    yum install -y file fontconfig fontconfig-devel systemtap-sdt-devel # Not included above ...
    yum install -y git bzip2 xz openssl pigz which # pigz/which not strictly needed but help in final compression
    if grep -i release.6 /etc/redhat-release; then
      if [ ! -r /usr/local/bin/autoconf ]; then
        curl https://ftp.gnu.org/gnu/autoconf/autoconf-2.69.tar.gz | tar xpfz - || exit 1
        (cd autoconf-2.69 && ./configure --prefix=/usr/local && make install)
      fi
    fi
  fi
}

# ant required for --create-sbom
downloadAnt() {
  if [ ! -r /usr/local/apache-ant-${ANT_VERSION}/bin/ant ]; then
    echo Downloading ant for SBOM creation:
    curl https://archive.apache.org/dist/ant/binaries/apache-ant-${ANT_VERSION}-bin.zip > /tmp/apache-ant-${ANT_VERSION}-bin.zip
    (cd /usr/local && unzip -qn /tmp/apache-ant-${ANT_VERSION}-bin.zip)
    rm /tmp/apache-ant-${ANT_VERSION}-bin.zip
    echo Downloading ant-contrib-${ANT_CONTRIB_VERSION}:
    curl -L https://sourceforge.net/projects/ant-contrib/files/ant-contrib/${ANT_CONTRIB_VERSION}/ant-contrib-${ANT_CONTRIB_VERSION}-bin.zip > /tmp/ant-contrib-${ANT_CONTRIB_VERSION}-bin.zip
    (unzip -qnj /tmp/ant-contrib-${ANT_CONTRIB_VERSION}-bin.zip ant-contrib/ant-contrib-${ANT_CONTRIB_VERSION}.jar -d /usr/local/apache-ant-${ANT_VERSION}/lib)
    rm /tmp/ant-contrib-${ANT_CONTRIB_VERSION}-bin.zip
  fi
}

# get the TEMURIN_VERSION form the SBOM metadata
getTemurinVersion() {
  TEMVER_MAJOR=$(grep '"major":' "$SBOM" | tr -d ' ,' | cut -d':' -f2)
  TEMVER_MINOR=$(grep '"minor":' "$SBOM" | tr -d ' ,' | cut -d':' -f2)
  TEMVER_SECURITY=$(grep '"security":' "$SBOM" | tr -d ' ,' | cut -d':' -f2)
  TEMVER_BUILD=$(grep '"build":' "$SBOM" | tr -d ' ,' | cut -d':' -f2)

  TEMURIN_VERSION="$TEMVER_MAJOR"
  if [ "$TEMVER_SECURITY" != "0" ]; then
    TEMURIN_VERSION="$TEMURIN_VERSION.$TEMVER_MINOR.$TEMVER_SECURITY"
  fi
  TEMURIN_VERSION="$TEMURIN_VERSION+$TEMVER_BUILD"
}

setEnvironment() {
  export CC="${LOCALGCCDIR}/bin/gcc-${GCCVERSION}"
  export CXX="${LOCALGCCDIR}/bin/g++-${GCCVERSION}"
  export LD_LIBRARY_PATH="${LOCALGCCDIR}/lib64"
  # /usr/local/bin required to pick up the new autoconf if required
  export PATH="${LOCALGCCDIR}/bin:/usr/local/bin:/usr/bin:$PATH:/usr/local/apache-ant-${ANT_VERSION}/bin"
  ls -ld "$CC" "$CXX" "/usr/lib/jvm/jdk-${BOOTJDK_VERSION}/bin/javac" || exit 1
}

cleanBuildInfo() {
  # BUILD_INFO name of OS level build was built on will likely differ
  sed -i '/^BUILD_INFO=.*$/d' "jdk-${TEMURIN_VERSION}/release"
  sed -i '/^BUILD_INFO=.*$/d' "compare.$$/jdk-${TEMURIN_VERSION}/release"
}

downloadTooling() {
  if [ ! -r "/usr/lib/jvm/jdk-${BOOTJDK_VERSION}/bin/javac" ]; then
    echo "Retrieving boot JDK $BOOTJDK_VERSION" && mkdir -p /usr/lib/jvm && curl -L "https://api.adoptopenjdk.net/v3/binary/version/jdk-${BOOTJDK_VERSION}/linux/${NATIVE_API_ARCH}/jdk/hotspot/normal/adoptopenjdk?project=jdk" | (cd /usr/lib/jvm && tar xpzf -)
  fi
  if [ ! -r "${LOCALGCCDIR}/bin/g++-${GCCVERSION}" ]; then
    echo "Retrieving gcc $GCCVERSION" && curl "https://ci.adoptium.net/userContent/gcc/gcc$(echo "$GCCVERSION" | tr -d .).$(uname -m).tar.xz" | (cd /usr/local && tar xJpf -) || exit 1
  fi
  if [ ! -r temurin-build ]; then
    git clone https://github.com/adoptium/temurin-build || exit 1
  fi
  (cd temurin-build && git checkout "$TEMURIN_BUILD_SHA")
}

checkAllVariablesSet() {
    [ -z "$SBOM" ] || [ -z "${BOOTJDK_VERSION}" ] || [ -z "${TEMURIN_BUILD_SHA}" ] || [ -z "${TEMURIN_BUILD_ARGS}" ] || [ -z "${TEMURIN_VERSION}" ] && echo "Could not determine one of the variables - run with sh -x to diagnose" && sleep 10 && exit 1
}

installPrereqs
downloadAnt

echo "Retrieving and parsing SBOM from $SBOM_URL"
curl -LO "$SBOM_URL"
SBOM=$(basename "$SBOM_URL")
BOOTJDK_VERSION=$(grep configure_arguments "$SBOM" | tr ' ' \\n | grep ^Temurin- | uniq | cut -d- -f2)
GCCVERSION=$(tr ' ' \\n < "$SBOM" | grep CC= | cut -d- -f2 | cut -d\\ -f1)
LOCALGCCDIR=/usr/local/gcc$(echo "$GCCVERSION" | cut -d. -f1)
TEMURIN_BUILD_SHA=$(awk -F'"' '/buildRef/{print$4}' "$SBOM"  | cut -d/ -f7)
TEMURIN_BUILD_ARGS=$(grep makejdk_any_platform_args "$SBOM" | cut -d\" -f4 | sed -e "s/--disable-warnings-as-errors --enable-dtrace --without-version-pre --without-version-opt/'--disable-warnings-as-errors --enable-dtrace --without-version-pre --without-version-opt'/" -e "s/ --disable-warnings-as-errors --enable-dtrace/ '--disable-warnings-as-errors --enable-dtrace'/" -e 's/\\n//g' -e "s,--jdk-boot-dir [^ ]*,--jdk-boot-dir /usr/lib/jvm/jdk-$BOOTJDK_VERSION,g")

getTemurinVersion

NATIVE_API_ARCH=$(uname -m)
if [ "${NATIVE_API_ARCH}" = "x86_64" ]; then NATIVE_API_ARCH=x64; fi
if [ "${NATIVE_API_ARCH}" = "armv7l" ]; then NATIVE_API_ARCH=arm; fi

checkAllVariablesSet

downloadTooling
setEnvironment

if [ ! -d "jdk-${TEMURIN_VERSION}" ]; then
   if [ -z "$TARBALL_URL" ]; then
       TARBALL_URL="https://api.adoptopenjdk.net/v3/binary/version/jdk-${TEMURIN_VERSION}/linux/${NATIVE_API_ARCH}/jdk/hotspot/normal/adoptopenjdk?project=jdk"
   fi
   echo Retrieving original tarball from adoptium.net && curl -L "$TARBALL_URL" | tar xpfz - && ls -lart "$PWD/jdk-${TEMURIN_VERSION}" || exit 1
fi

echo "  cd temurin-build && ./makejdk-any-platform.sh $TEMURIN_BUILD_ARGS 2>&1 | tee build.$$.log" | sh

echo Comparing ...
mkdir compare.$$
tar xpfz temurin-build/workspace/target/OpenJDK*-jdk_*tar.gz -C compare.$$

cleanBuildInfo

if diff -r "jdk-${TEMURIN_VERSION}" "compare.$$/jdk-$TEMURIN_VERSION" 2>&1 > "reprotest.$(uname).$TEMURIN_VERSION.diff"; then
    echo "Compare identical !"
    exit 0
else
    cat "reprotest.$(uname).$TEMURIN_VERSION.diff"
    echo "Differences found..., logged in: reprotest.$(uname).$TEMURIN_VERSION.diff"
    exit 1
fi

