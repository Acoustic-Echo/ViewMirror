# CMAKE_PROJECT_INCLUDE hook: use a verified Microsoft librarian for archives
# of GNU/UCRT64 COFF objects. Compilation, linking and runtime stay in UCRT64.
if(NOT WIN32 OR NOT MINGW OR NOT CMAKE_C_COMPILER_ID STREQUAL "GNU")
  message(FATAL_ERROR "This archive configuration requires Windows MinGW GCC.")
endif()
if(NOT viewMirror_COFF_LIBRARIAN OR NOT EXISTS "${viewMirror_COFF_LIBRARIAN}")
  message(FATAL_ERROR "The verified COFF librarian does not exist: ${viewMirror_COFF_LIBRARIAN}")
endif()
# A compiler-info file from a previous configure can shadow CMAKE_AR's cache.
# Set the active normal variable after the compiler information was loaded.
set(CMAKE_AR "${viewMirror_COFF_LIBRARIAN}")
foreach(lang IN ITEMS C CXX)
  set(CMAKE_${lang}_ARCHIVE_CREATE "<CMAKE_AR> /NOLOGO /OUT:<TARGET> <OBJECTS>")
  set(CMAKE_${lang}_ARCHIVE_APPEND "<CMAKE_AR> /NOLOGO /OUT:<TARGET> <TARGET> <OBJECTS>")
  # LIB creates the archive index itself; GNU ranlib is not needed.
  set(CMAKE_${lang}_ARCHIVE_FINISH "")
endforeach()
message(STATUS "COFF archives: verified Microsoft librarian ${CMAKE_AR}")
