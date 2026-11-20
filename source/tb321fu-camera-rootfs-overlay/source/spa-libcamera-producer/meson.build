project(
  'y700-spa-libcamera',
  ['cpp'],
  version : '1.0.6-y700-cleanminimal',
  default_options : ['cpp_std=c++17'],
)

spa_dep = dependency('libspa-0.2')
pthread_dep = dependency('threads')

libcamera_staging = get_option('libcamera_staging')
if libcamera_staging == ''
  libcamera_dep = dependency('libcamera')
  libcamera_includes = []
else
  libcamera_include_dir = libcamera_staging / 'opt/libcamera-y700/include/libcamera'
  libcamera_lib_dir = libcamera_staging / 'opt/libcamera-y700/lib/aarch64-linux-gnu'
  libcamera_dep = declare_dependency(
    link_args : [
      '-L' + libcamera_lib_dir,
      '-l:libcamera.so',
      '-l:libcamera-base.so',
    ],
  )
  libcamera_includes = [include_directories(libcamera_include_dir)]
endif

configinc = include_directories('.', 'spa/plugins/libcamera')
spa_plugindir = get_option('prefix') / get_option('libdir') / 'spa-0.2'

libcamera_sources = files(
  'spa/plugins/libcamera/libcamera-plugin.cpp',
  'spa/plugins/libcamera/libcamera-manager.cpp',
  'spa/plugins/libcamera/libcamera-device.cpp',
  'spa/plugins/libcamera/libcamera-source.cpp',
)

shared_library(
  'spa-libcamera',
  libcamera_sources,
  include_directories : [configinc] + libcamera_includes,
  dependencies : [spa_dep, libcamera_dep, pthread_dep],
  link_args : ['-Wl,-z,nodelete'],
  install_rpath : '/opt/libcamera-y700/lib/aarch64-linux-gnu',
  install : true,
  install_dir : spa_plugindir / 'libcamera',
)
