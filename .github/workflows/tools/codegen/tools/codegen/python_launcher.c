/* Android ARM64 entry point for the embedded CPython runtime. */
#include <Python.h>

int main(int argc, char **argv) {
    return Py_BytesMain(argc, argv);
}
