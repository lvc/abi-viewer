ABI Viewer 1.0
==============

ABI Viewer — a tool to visualize ABI structure of a C/C++ software library.

Currently supported architectures: x86_64, x86.

Contents
--------

1. [ About           ](#about)
2. [ Install         ](#install)
3. [ Create ABI view ](#create-abi-view)
4. [ Create ABI diff ](#create-abi-diff)


About
-----

The tool is intended for developers of software libraries and Linux maintainers who are interested in ensuring backward binary compatibility, i.e. allow old applications to run with newer library versions.

Install
-------

    sudo make install prefix=/usr

###### Requires

* Perl 5
* ABI Dumper EE >= 1.4 (https://github.com/lvc/abi-dumper)
* Elfutils
* Vtable-Dumper >= 1.2 (https://github.com/lvc/vtable-dumper)

Create ABI view
---------------

Input objects should be compiled with `-g -Og -fno-eliminate-unused-debug-types` additional options to contain DWARF debug info.

    abi-viewer libTest.so -o ReportDir/

###### Demo

See example for libssh: https://abi-laboratory.pro/index.php?view=live_readelf&l=libssh&v=0.7.1&obj=a7d4a

Offline report copy is in [ this subdirectory ](/demo/libssh/0.7.1/a7d4a/).

Create ABI diff
---------------

    abi-viewer -diff libTest.so.0 libTest.so.1 -o DiffReportDir/
