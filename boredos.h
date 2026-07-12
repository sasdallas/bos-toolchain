#undef TARGET_BOREDOS
#define TARGET_BOREDOS 1

#undef TARGET_OS_CPP_BUILTINS
#define TARGET_OS_CPP_BUILTINS()      \
  do {                                \
    builtin_define ("__boredos__");   \
    builtin_define ("__unix__");      \
    builtin_assert ("system=boredos");\
    builtin_assert ("system=unix");   \
  } while (0)

#undef STARTFILE_SPEC
#define STARTFILE_SPEC \
  "%{!shared: %{static:crt0.o%s; :crt1.o%s}} crti.o%s \
   %{static:crtbeginT.o%s; shared|pie:crtbeginS.o%s; :crtbegin.o%s}"

#undef ENDFILE_SPEC
#define ENDFILE_SPEC \
  "%{static:crtend.o%s; shared|pie:crtendS.o%s; :crtend.o%s} crtn.o%s"

#undef LIB_SPEC
#define LIB_SPEC "-lc"

#undef DYNAMIC_LINKER
#define DYNAMIC_LINKER "/lib/ld.so"

#undef LINK_SPEC
#define LINK_SPEC "%{shared:-shared} \
  %{!shared: %{!static: %{rdynamic:-export-dynamic} \
  -dynamic-linker " DYNAMIC_LINKER "} %{static:-static}}"
