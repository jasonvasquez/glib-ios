#!/bin/bash



# Configurable globals
readonly MIN_IOS_VERSION="7.0"

readonly LIBFFI_VERSION="3.2.1"
readonly GLIB_VERSION="2.47.1"
readonly GETTEXT_VERSION="0.19.6"
readonly ICONV_VERSION="1.14"

readonly ARCHS=(armv7 armv7s arm64 i386 x86_64)




# Calculated globals
readonly ROOT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
readonly DEPS_DIR="${ROOT_DIR}/dependencies"
readonly WORK_DIR="${ROOT_DIR}/work"
readonly LOGFILE="${ROOT_DIR}/build.log"

readonly LIPO="$(xcrun --sdk iphoneos -f lipo)"

readonly IPHONEOS_CC="$(xcrun --sdk iphoneos -f clang)"
readonly IPHONEOS_CXX="$(xcrun --sdk iphoneos -f clang++)"
readonly IPHONEOS_SDK=$(xcrun --sdk iphoneos --show-sdk-path)
readonly IPHONEOS_CFLAGS="-isysroot $IPHONEOS_SDK -miphoneos-version-min=$MIN_IOS_VERSION"

readonly IPHONESIM_CC="$(xcrun --sdk iphonesimulator -f clang)"
readonly IPHONESIM_CXX="$(xcrun --sdk iphonesimulator -f clang++)"
readonly IPHONESIM_SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
readonly IPHONESIM_CFLAGS="-isysroot $IPHONESIM_SDK -mios-simulator-version-min=$MIN_IOS_VERSION"

log() {
  local msg=$1
  local now=$(date "+%Y-%m-%d% %H:%M:%S")

  echo "[${now}] $msg" >> ${LOGFILE}
}

is_file() {
  local file=$1

  [[ -f $file ]]
}

is_dir() {
  local dir=$1

  [[ -d $dir ]]
}

is_empty() {
  local var=$1

  [[ -z $var ]]
}

is_universal() {
  local path=$1

  file $path | grep -q universal
}

is_iphone_arch() {
  local arch=$1

  [[ $arch == arm* ]]
}

fetch() {
  local name=$1
  local url=$2
  local dest=$3

  run "curl -s -L -o $dest $url" "Fetching $name"
}


run() {
  local cmd=$1
  local msg=$2

  log "> ${cmd}"

  echo -n "${msg}..."
  $cmd >> $LOGFILE 2>&1 && echo "done." || {
    log "FAILED with exit code $?"
    echo "failed."
    echo "Build Failed. See ${LOGFILE} for details."
    exit 1
  }
  log "OK."
}

clean_up_prior_build() {
  is_file "${LOGFILE}" \
    && run "rm -f ${LOGFILE}" "Removing old logfile"

  is_dir "${WORK_DIR}" \
    && run "rm -rf ${WORK_DIR}" "Removing old work tree"

  mkdir -p "${WORK_DIR}"
}


# Given an architecture (armv7, i386, etc.) in $1,
# echo out the correct autoconf host triplet
host_for_arch() {
  local readonly arch=$1
  case "$arch" in
    armv*)
      echo "arm-apple-darwin"
      ;;
    arm64)
      echo "aarch64-apple-darwin"
      ;;
    x86_64)
      echo "x86_64-apple-darwin"
      ;;
    i386)
      echo "i386-apple-darwin"
      ;;
    *)
      local msg="ERROR: Unable to determine architecture triplet for $arch"
      log $msg
      echo $msg
      exit 1
  esac
}

# Given an architecture (armv7, i386, etc.) in $1,
# export CFLAGS, CXXFLAGS, etc. appropriate for that arch
set_build_env_for_arch() {
  local readonly arch=$1
  case "$arch" in
    arm*)
      export CC=$IPHONEOS_CC
      export CXX=$IPHONEOS_CXX
      export CFLAGS="$IPHONEOS_CFLAGS"
      ;;
    x86_64 | i386)
      export CC=$IPHONESIM_CC
      export CXX=$IPHONESIM_CXX
      export CFLAGS="$IPHONESIM_CFLAGS"
      ;;
    *)
      local msg="ERROR: Unable to set environment variables for $arch"
      log $msg
      echo $msg
      exit 1
  esac

  export PKG_CONFIG_PATH="${ROOT_DIR}/dependencies/libffi/${arch}/lib/pkgconfig"

  export CFLAGS="$CFLAGS -arch ${arch}"
  export CFLAGS="$CFLAGS -I${ROOT_DIR}/dependencies/gettext/${arch}/include"

  export CXXFLAGS=$CFLAGS
  export CPPFLAGS=$CFLAGS
  export LDFLAGS="-L${ROOT_DIR}/dependencies/libffi/fat/lib -L${ROOT_DIR}/dependencies/gettext/fat/lib"
  export ac_cv_func__NSGetEnviron=no
}

unset_build_env() {
  unset PKG_CONFIG_PATH CC CXX CFLAGS CXXFLAGS CPPFLAGS LDFLAGS ac_cv_func__NSGetEnviron
}


# Given a pattern like dependencies/libffi/ARCH/lib/libffi.a
# fatify will locate the static libs for each arch in $ARCHS
# (replacing the magic string 'ARCH' with the appropriate architecture)
# and emit a fat binary in, e.g.,  dependencies/libffi/fat/lib/libffi.a
fatify() {
  local pattern=$1

  local libshortname=$(basename ${pattern})
  local destfile=$(echo ${pattern} | sed s/ARCH/fat/)
  local destdir=$(dirname ${destfile})
  local tempdir="${ROOT_DIR}/.lipo_tmp"

  is_dir "${tempdir}" \
    && run "rm -rf ${tempdir}" "Removing old universal prep temp directory"
  run "mkdir ${tempdir}" "Creating temp directory for universal binary prep"

  local archlist=""
  for arch in "${ARCHS[@]}"; do
    local path=$(echo $pattern | sed s/ARCH/$arch/)
    local libname=${path}

    if $(is_universal $path); then
      local tmpname="${tempdir}/${arch}_${libshortname}"
      local cmd="${LIPO} ${path} -thin ${arch} -output ${tmpname}"
      run "${cmd}" "Extracting $arch from ${path}"
      libname=${tmpname}
    fi

    archlist="${archlist} -arch ${arch} ${libname}"
  done

  run "mkdir -p ${destdir}" "Creating universal binary output directory ${destdir}"

  local cmd="${LIPO} -create -output ${destfile} ${archlist}"
  run "${cmd}" "Creating universal binary for $(basename ${destfile})"
}

build_iconv() {
  local iconvarchive="${WORK_DIR}/iconv.tar.gz"
  local iconvdir="${WORK_DIR}/libiconv-${ICONV_VERSION}"
  local prefix="${DEPS_DIR}/libiconv"

  echo "Beginning build of libiconv"

  ! is_file $iconvarchive \
    && fetch "libiconv" \
      "http://ftp.gnu.org/pub/gnu/libiconv/libiconv-${ICONV_VERSION}.tar.gz" \
      ${iconvarchive}

  is_dir $prefix \
    && run "rm -rf $prefix" "  Removing old libiconv install prefix directory"


  for arch in "${ARCHS[@]}"; do
    set_build_env_for_arch ${arch}

    run "env" "Logging environment"

    echo "Building libiconv for $arch"

    is_dir $iconvdir \
      && run "rm -rf $iconvdir" "  Removing old libiconv build directory"

    cd "${WORK_DIR}"
    run "tar xzf ${iconvarchive}" "  Unpacking libiconv"

    cd "${iconvdir}"

    is_iphone_arch ${arch} \
      && sed -i '' 's/if defined __APPLE__ \&\& defined __MACH__/if defined __APPLE__ \&\& defined __MACH__ \&\& defined SKIPIT/' srclib/unistd.in.h

    local host_type=$(host_for_arch ${arch})
    if [ "$arch" == "arm64" ]; then
      host_type="arm-apple-darwin"
    fi

    read -d '' cmd <<EOF
      ./configure \
        --prefix=$prefix/${arch} \
        --enable-static \
        --disable-shared \
        --host=${host_type}
EOF

    run "${cmd}" "  Configuring libiconv for ${arch}"
    run "make -j12" "  Building libiconv for ${arch}"

    run "mkdir -p ${prefix}/${arch}" "  Creating output directory for ${arch}"
    run "make install" "  Installing libiconv for ${arch} into ${prefix}/${arch}"
  done

  cd ${ROOT_DIR}
  local iconvlibs=(libcharset.a libiconv.a)
  for lib in "${iconvlibs[@]}"; do
    fatify "dependencies/libiconv/ARCH/lib/${lib}"
  done

  unset_build_env
  unset cmd
}


build_gettext() {
  local gtarchive="${WORK_DIR}/gt.tar.gz"
  local gtdir="${WORK_DIR}/gettext-${GETTEXT_VERSION}"
  local prefix="${DEPS_DIR}/gettext"

  echo "Beginning build of gettext"

  ! is_file $gtarchive \
    && fetch "gettext" \
      "http://ftp.gnu.org/pub/gnu/gettext/gettext-${GETTEXT_VERSION}.tar.gz" \
      ${gtarchive}

  is_dir $prefix \
    && run "rm -rf $prefix" "  Removing old gettext install prefix directory"


  for arch in "${ARCHS[@]}"; do
    set_build_env_for_arch ${arch}

    run "env" "Logging environment"

    echo "Building gettext for $arch"

    is_dir $gtdir \
      && run "rm -rf $gtdir" "  Removing old gettext build directory"

    cd "${WORK_DIR}"
    run "tar xzf ${gtarchive}" "  Unpacking gettext"

    cd "${gtdir}"

    read -d '' cmd <<EOF
      ./configure \
        --prefix=$prefix/${arch} \
        --enable-static \
        --disable-shared \
        --host=$(host_for_arch ${arch})
EOF

    run "${cmd}" "  Configuring gettext for ${arch}"
    run "make -j12" "  Building gettext for ${arch}"

    run "mkdir -p ${prefix}/${arch}" "  Creating output directory for ${arch}"
    run "make install" "  Installing gettext for ${arch} into ${prefix}/${arch}"
  done

  cd ${ROOT_DIR}
  local gtlibs=(libasprintf.a libgettextpo.a libintl.a)
  for lib in "${gtlibs[@]}"; do
    fatify "dependencies/gettext/ARCH/lib/${lib}"
  done

  unset_build_env
  unset cmd

}

build_glib() {
  local glibzip="${WORK_DIR}/glib.zip"
  local glibdir="${WORK_DIR}/glib-${GLIB_VERSION}"
  local prefix="${DEPS_DIR}/glib"

  echo "Beginning build of glib"

  ! is_file $glibzip \
    && fetch "glib" \
      "https://github.com/GNOME/glib/archive/${GLIB_VERSION}.zip" \
      ${glibzip}

  is_dir $prefix \
    && run "rm -rf $prefix" "Removing old glib install prefix directory"


  for arch in "${ARCHS[@]}"; do
    set_build_env_for_arch ${arch}

    run "env" "Logging environment"

    echo "Building glib for $arch"

    is_dir $glibdir \
      && run "rm -rf $glibdir" "  Removing old glib build directory"

    cd "${WORK_DIR}"
    run "unzip ${glibzip}" "  Unpacking glib"

    cd "${glibdir}"
    export NOCONFIGURE=true
    run "./autogen.sh" "  Bootstrapping autoconf for glib"
    unset NOCONFIGURE

    read -d '' cmd <<EOF
      ./configure \
        --prefix=$prefix/${arch} \
        --enable-static \
        --disable-shared \
        --host=$(host_for_arch ${arch}) \
        --with-libiconv=native
EOF

    run "${cmd}" "  Configuring glib for ${arch}"
    run "make -j12" "  Building glib for ${arch}"

    run "mkdir -p ${prefix}/${arch}" "  Creating output directory for ${arch}"
    run "make install" "  Installing glib for ${arch} into ${prefix}/${arch}"
  done

exit
  cd ${ROOT_DIR}
  fatify "dependencies/libffi/ARCH/lib/libffi.a"

  unset_build_env
  unset cmd
}




build_libffi() {
  local ffizip="${WORK_DIR}/ffi.zip"
  local ffidir="${WORK_DIR}/libffi-${LIBFFI_VERSION}"
  local prefix="${DEPS_DIR}/libffi"

  echo "Beginning build of dependency: libffi"

  ! is_file $ffizip \
    && fetch "libffi" \
      "https://github.com/atgreen/libffi/archive/v${LIBFFI_VERSION}.zip" \
      ${ffizip}

  is_dir $ffidir \
    && run "rm -rf $ffidir" "Removing old libffi build directory"

  is_dir $prefix \
    && run "rm -rf $prefix" "Removing old libffi install prefix directory"

  cd "${WORK_DIR}"
  run "unzip ${ffizip}" "Unpacking libffi"

  cd "${ffidir}"
  run "./autogen.sh" "Bootstrapping autoconf for libffi"

  for arch in "${ARCHS[@]}"; do
    set_build_env_for_arch ${arch}

    echo "Building libffi for $arch"

    is_file config.status \
      && run "make distclean" "  Cleaning up from last run"

    read -d '' cmd <<EOF
      ./configure \
        --prefix=$prefix/${arch} \
        --enable-static \
        --disable-shared \
        --host=$(host_for_arch ${arch})
EOF

    run "${cmd}" "  Configuring libffi for ${arch}"
    run "make -j12" "  Building libffi for ${arch}"

    run "mkdir -p ${prefix}/${arch}" "  Creating output directory for ${arch}"
    run "make install" "  Installing libffi for ${arch} into ${prefix}/${arch}"
  done

  cd ${ROOT_DIR}
  fatify "dependencies/libffi/ARCH/lib/libffi.a"

  unset_build_env
  unset cmd
}


main() {
  # clean_up_prior_build
  log "Beginning build"

  build_libffi
  build_iconv
  build_gettext
  build_glib
}

main
