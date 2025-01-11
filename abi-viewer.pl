#!/usr/bin/perl
##################################################################
# ABI Viewer 1.0
# A tool to visualize ABI structure of a C/C++ software library
#
# Copyright (C) 2014-2025 Andrey Ponomarenko's ABI Laboratory
#
# Written by Andrey Ponomarenko
#
# PLATFORMS
# =========
#  Linux (x86, x86_64)
#
# REQUIREMENTS
# ============
#  Perl 5 (5.8 or newer)
#  ABI Dumper EE (1.4 or newer)
#  Elfutils (eu-readelf)
#  Vtable-Dumper (1.2 or newer)
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License as published by the Free Software Foundation; either
# version 2.1 of the License, or (at your option) any later version.
#
# This library is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# Lesser General Public License for more details.
#
# You should have received a copy of the GNU Lesser General Public
# License along with this library; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston,
# MA  02110-1301 USA
#
# Reports of the tool can be publicly shared under the Creative
# Commons BY-SA License.
#
##################################################################
use Getopt::Long;
Getopt::Long::Configure ("posix_default", "no_ignore_case");
use File::Path qw(mkpath rmtree);
use File::Temp qw(tempdir);
use File::Basename qw(dirname basename);
use Digest::MD5 qw(md5_hex);
use Cwd qw(abs_path);

my $TOOL_VERSION = "1.0";
my $TMP_DIR = tempdir(CLEANUP=>1);

# Internal modules
my $MODULES_DIR = get_Modules();
push(@INC, dirname($MODULES_DIR));

my $ABI_DUMPER = "abi-dumper";
my $ABI_DUMPER_VERSION = "1.4";

my ($Help, $DumpVersion, $Output, $Diff, $SkipStd,
$OutExtraInfo, $SymbolsListPath, $PublicHeadersPath,
$TargetVersion1, $TargetVersion2, $IgnoreTagsPath,
$KernelExport, $ShowPrivateABI, $ShowVersion);

my $CmdName = basename($0);
my $MD5_LEN = 5;

my %ERROR_CODE = (
    "Success"=>0,
    # Undifferentiated error code
    "Error"=>2,
    # System command is not found
    "Not_Found"=>3,
    # Cannot access input files
    "Access_Error"=>4,
    # Cannot find a module
    "Module_Error"=>9
);

my $HomePage = "http://abi-laboratory.pro/";

my $ShortUsage = "ABI Viewer $TOOL_VERSION
A tool to visualize ABI structure of a C/C++ software library
Copyright (C) 2014-2025 Andrey Ponomarenko's ABI Laboratory
License: GNU LGPL 2.1

Usage: $CmdName [options] [object]
Example:
  $CmdName libTest.so -o Dir/
  $CmdName -diff libTest.so.0 libTest.so.1 -o Dir/
  
The input object should be built with -g -Og GCC options.
More info: $CmdName --help\n";

if($#ARGV==-1)
{
    printMsg("INFO", $ShortUsage);
    exit(0);
}

GetOptions("h|help!" => \$Help,
  "v|version!" => \$ShowVersion,
  "dumpversion!" => \$DumpVersion,
# general options
  "o|output|dir=s" => \$Output,
  "diff" => \$Diff,
# adv. options
  "extra-info=s" => \$OutExtraInfo,
  "skip-std!" => \$SkipStd,
  "symbols-list=s" => \$SymbolsListPath,
  "public-headers=s" =>\$PublicHeadersPath,
  "ignore-tags=s" => \$IgnoreTagsPath,
  "kernel-export!" => \$KernelExport,
  "show-private!" => \$ShowPrivateABI,
  "vnum|vnum1=s" => \$TargetVersion1,
  "vnum2=s" => \$TargetVersion2
) or errMsg();

sub errMsg()
{
    printMsg("INFO", "\n".$ShortUsage);
    exit($ERROR_CODE{"Error"});
}

my $HelpMessage="
NAME:
  ABI Viewer ($CmdName)
  Visualize ABI interface structure of a C/C++ software library

DESCRIPTION:
  ABI Viewer is a tool to visualize ABI interface structure of a
  C/C++ software library and to visualize ABI changes made in the
  library.
  
  The tool is intended for developers of software libraries and
  Linux maintainers who are interested in ensuring backward
  binary compatibility, i.e. allow old applications to run with
  newer library versions.
  
  The tool allows to maintain binary compatibility of interfaces
  and data structures in high detail.

  This tool is free software: you can redistribute it and/or modify it
  under the terms of the GNU LGPL 2.1.
  
  Reports of the tool can be publicly shared under the Creative
  Commons BY-SA License.

USAGE:
  $CmdName [options] [object]

EXAMPLES:
  $CmdName libTest.so -o Dir/
  $CmdName -diff libTest.so.0 libTest.so.1 -o Dir/

INFORMATION OPTIONS:
  -h|-help
      Print this help.

  -v|-version
      Print version information.

  -dumpversion
      Print the tool version ($TOOL_VERSION) and don't do
      anything else.

GENERAL OPTIONS:
  -o|-output|-dir PATH
      Path to the report directory.
  
  -diff P1 P2
      Compare two objects and create report on changes in the ABI.
      P1, P2 - paths to ABI dumps or shared objects to compare.

ADV. OPTIONS:
  -extra-info DIR
      Dump extra analysis info to DIR. You can pass it instead of
      the initial object.
  
  -skip-std
      Do not show symbols from 'std' and '__gnu_cxx' namespaces (C++ only).
  
  -symbols-list PATH
      Specify a file with the list of symbols to view. This may be
      a list of \"public\" symbols in the object.
  
  -public-headers PATH
      Path to directory with public header files or to file with
      the list of header files. This option allows to filter out
      private symbols from the ABI view.
  
  -ignore-tags PATH
      Path to ignore.tags file to help ctags tool to read
      symbols in header files.
  
  -kernel-export
      Dump symbols exported by the Linux kernel and modules, i.e.
      symbols declared in the ksymtab section of the object and
      system calls.
  
  -vnum NUM
      Set version of the input object to NUM.
  
  -vnum1 NUM
  -vnum2 NUM
      Set versions of compared objects.
";

sub helpMsg() {
    printMsg("INFO", $HelpMessage);
}

# ABI Info
my %ABI;
my %EXTRA = (
    "1" => $TMP_DIR."/extra-info",
    "2" => $TMP_DIR."/extra-info-2"
);
my $BYTE = 8;

# ABI Symbols
my %Sort_Symbols;
my %SymbolID;
my %TypeID;
my %MappedType;
my %MappedType_R;

# Report
my $SHOW_DEV = 1;

# Diff
my %AddedSymbols;
my %RemovedSymbols;
my %ChangedSymbols;
my %AddedTypes;
my %RemovedTypes;
my %AddedTypes_All;
my %RemovedTypes_All;
my %ChangedTypes;
my %ChangeStatus;
my %PsetStatus;

# Usage
my %FuncParam;
my %FuncReturn;
my %TypeMemb;
my %TmplParam_T;
my %TmplParam_S;
my %FPtrParam;

sub get_Modules()
{
    my $TOOL_DIR = dirname($0);
    my @SEARCH_DIRS = (
        # tool's directory
        abs_path($TOOL_DIR),
        # relative path to modules
        abs_path($TOOL_DIR)."/../share/abi-viewer",
        # install path
        'MODULES_INSTALL_PATH'
    );
    foreach my $DIR (@SEARCH_DIRS)
    {
        if(not $DIR=~/\A\//)
        { # relative path
            $DIR = abs_path($TOOL_DIR)."/".$DIR;
        }
        if(-d $DIR."/modules") {
            return $DIR."/modules";
        }
    }
    exitStatus("Module_Error", "can't find modules");
}

sub loadModule($)
{
    my $Name = $_[0];
    my $Path = $MODULES_DIR."/Internals/$Name.pm";
    if(not -f $Path) {
        exitStatus("Module_Error", "can't access \'$Path\'");
    }
    require $Path;
}

sub readModule($$)
{
    my ($Module, $Name) = @_;
    my $Path = $MODULES_DIR."/Internals/$Module/".$Name;
    if(not -f $Path) {
        exitStatus("Module_Error", "can't access \'$Path\'");
    }
    return readFile($Path);
}

sub exitStatus($$)
{
    my ($Code, $Msg) = @_;
    printMsg("ERROR", $Msg);
    exit($ERROR_CODE{$Code});
}

sub printMsg($$)
{
    my ($Type, $Msg) = @_;
    if($Type!~/\AINFO/) {
        $Msg = $Type.": ".$Msg;
    }
    if($Type!~/_C\Z/) {
        $Msg .= "\n";
    }
    if($Type eq "ERROR") {
        print STDERR $Msg;
    }
    else {
        print $Msg;
    }
}

sub cmpVersions($$)
{ # compare two versions in dotted-numeric format
    my ($V1, $V2) = @_;
    return 0 if($V1 eq $V2);
    my @V1Parts = split(/\./, $V1);
    my @V2Parts = split(/\./, $V2);
    for (my $i = 0; $i <= $#V1Parts && $i <= $#V2Parts; $i++)
    {
        return -1 if(int($V1Parts[$i]) < int($V2Parts[$i]));
        return 1 if(int($V1Parts[$i]) > int($V2Parts[$i]));
    }
    return -1 if($#V1Parts < $#V2Parts);
    return 1 if($#V1Parts > $#V2Parts);
    return 0;
}

sub viewABI()
{
    rmtree($Output."/usage");
    rmtree($Output."/symbols");
    rmtree($Output."/types");
    rmtree($Output."/css");
    rmtree($Output."/js");
    
    unlink($Output."/symbols.html");
    unlink($Output."/types.html");
    unlink($Output."/live-readelf.html");
    
    writeFile("$Output/css/report.css", readModule("Styles", "Report.css"));
    writeFile("$Output/js/sort.js", readModule("Scripts", "Sort.js"));
    
    if(defined $Diff) {
        detectAddedRemoved();
    }
    
    printMsg("INFO", "Create type pages");
    foreach my $TID (sort {int($a)<=>int($b)} keys(%{$ABI{1}->{"TypeInfo"}}))
    {
        showTypeInfo($TID, 1);
        
        # if(defined $MappedType{$TID} and not defined $TypeID{2}{getTypeName($TID, 1)} and my $Mapped = $MappedType{$TID}) {
        #     showTypeInfo($Mapped, 2);
        # }
    }
    foreach my $Name (sort keys(%AddedTypes_All)) {
        showTypeInfo($TypeID{2}{$Name}, 2);
    }
    
    printMsg("INFO", "Create symbol pages");
    # foreach my $ID (sort {int($a)<=>int($b)} keys(%{$ABI{1}->{"SymbolInfo"}})) {
    foreach my $Name (sort keys(%{$SymbolID{1}})) {
        showSymbolInfo($SymbolID{1}{$Name}, 1);
    }
    foreach my $Name (sort keys(%AddedSymbols)) {
        showSymbolInfo($SymbolID{2}{$Name}, 2);
    }
    
    showSymbolList();
    showTypeList();
    
    if(not $Diff) {
        showReadelf($EXTRA{1}."/debug/elf-info");
    }
}

sub readABI($$)
{
    my ($Path, $VN) = @_;
    
    $Path = checkInput($Path, $VN);
    my $Content = readFile($Path);
    $ABI{$VN} = eval($Content);
    
    if(not $ABI{$VN}) {
        exitStatus("Error", "can't read ABI dump, please remove 'use strict' and retry");
    }
    elsif(not keys(%{$ABI{$VN}->{"SymbolInfo"}})
    or not keys(%{$ABI{$VN}->{"TypeInfo"}})) {
        exitStatus("Error", "not enough debug-info in the shared object, try to recompile it with '-g' option");
    }
    
    if(cmpVersions($ABI{$VN}->{"ABI_DUMPER_VERSION"}, $ABI_DUMPER_VERSION)<0) {
        exitStatus("Error", "incorrect version of input ABI dump");
    }
    
    if($ABI{$VN}->{"ExtraDump"} ne "On") {
        exitStatus("Error", "input ABI dump should be created with -extra-dump option");
    }
    
    foreach my $ID (keys(%{$ABI{$VN}->{"TypeInfo"}})) {
        $TypeID{$VN}{$ABI{$VN}->{"TypeInfo"}{$ID}{"Name"}} = $ID;
    }
    
    foreach my $ID (sort {int($a)<=>int($b)} keys(%{$ABI{$VN}->{"SymbolInfo"}}))
    {
        my %Info = %{$ABI{$VN}->{"SymbolInfo"}{$ID}};
        
        my $Name = $Info{"MnglName"};
        if(not $Name) {
            $Name = $Info{"ShortName"};
        }
        
        # TODO: fix duplicated entries in the ABI Dumper
        if(defined $SymbolID{$VN}{$Name})
        {
            if(defined $Info{"Param"})
            {
                if($Info{"Param"}{0}{"name"} eq "p1")
                {
                    next;
                }
            }
        }
        
        $SymbolID{$VN}{$Name} = $ID;
        
        if(not defined $Sort_Symbols{$Name})
        {
            $Sort_Symbols{$Name} = get_Signature(\%Info, $VN, 0, 0, undef);
            $Sort_Symbols{$Name}=~s/\A(vtable|typeinfo) for //g;
        }
        
        if($Info{"Kind"} eq "OBJECT")
        {
            if(isVTable($Name))
            {
                my $CId = $Info{"Class"};
                
                $ABI{$VN}->{"SymbolInfo"}{$ID}{"Source"} = $ABI{$VN}->{"TypeInfo"}{$CId}{"Source"};
                $ABI{$VN}->{"SymbolInfo"}{$ID}{"Header"} = $ABI{$VN}->{"TypeInfo"}{$CId}{"Header"};
            }
        }
        
        # Usage
        if($Info{"Bind"} and not (defined $SkipStd and isStd($Name)))
        {
            foreach my $N (sort keys(%{$Info{"Param"}}))
            {
                my $PTid = $Info{"Param"}{$N}{"type"};
                my $PName = $Info{"Param"}{$N}{"name"};
                my $BTid = get_BasicType($PTid, $VN);
                $FuncParam{$VN}{$BTid}{$ID}{$PName} = 1;
            }
            
            if(my $RTid = $Info{"Return"})
            {
                my $BTid = get_BasicType($RTid, $VN);
                $FuncReturn{$VN}{$BTid}{$ID} = 1;
            }
            
            foreach my $P (sort keys(%{$Info{"TParam"}}))
            {
                if(defined $TypeID{$P})
                {
                    my $PTid = $TypeID{$P};
                    my $BTid = get_BasicType($PTid, $VN);
                    $TmplParam_S{$VN}{$BTid}{$ID}{$P} = 1;
                }
            }
        }
    }
    
    foreach my $ID (keys(%{$ABI{$VN}->{"TypeInfo"}}))
    {
        my %Info = %{$ABI{$VN}->{"TypeInfo"}{$ID}};
        
        # Usage
        foreach my $N (sort keys(%{$Info{"Memb"}}))
        {
            if(my $MTid = $Info{"Memb"}{$N}{"type"})
            {
                my $Mname = $Info{"Memb"}{$N}{"name"};
                my $BTid = get_BasicType($MTid, $VN);
                $TypeMemb{$VN}{$BTid}{$ID}{$Mname} = 1;
            }
        }
        
        foreach my $P (sort keys(%{$Info{"TParam"}}))
        {
            if(defined $TypeID{$P})
            {
                my $PTid = $TypeID{$P};
                my $BTid = get_BasicType($PTid, $VN);
                $TmplParam_T{$VN}{$BTid}{$ID}{$P} = 1;
            }
        }
        
        # FuncPtr, MethodPtr
        foreach my $N (sort keys(%{$Info{"Param"}}))
        {
            my $PTid = $Info{"Param"}{$N}{"type"};
            my $BTid = get_BasicType($PTid, $VN);
            $FPtrParam{$VN}{$BTid}{$ID}{$N} = 1;
        }
        
        # FuncPtr, MethodPtr, FieldPtr
        if(my $RTid = $Info{"Return"})
        {
            my $BTid = get_BasicType($RTid, $VN);
            $FPtrParam{$VN}{$BTid}{$ID}{"ret"} = 1;
        }
    }
}

sub getTop($)
{
    my $Page = $_[0];
    
    my $Rel = "";
    
    if($Page=~/\A(symbols|types|live-readelf)\Z/) {
        $Rel = "";
    }
    elsif($Page=~/\A(symbol|type)\Z/) {
        $Rel = "../";
    }
    
    return $Rel;
}

sub showMenu($)
{
    my $Sel = $_[0];
    
    my $UrlPr = getTop($Sel);
    
    my $Menu = "";
    my $Title = "";
    
    if($Diff)
    {
        my $O1 = $ABI{1}->{"LibraryName"};
        my $O2 = $ABI{2}->{"LibraryName"};
        
        if($TargetVersion1)
        {
            $O1=~s/(\.so).+\Z/$1/;
            $O1 .= " ".$TargetVersion1;
        }
        
        if($TargetVersion2)
        {
            $O2=~s/(\.so).+\Z/$1/;
            $O2 .= " ".$TargetVersion2;
        }
        
        #$Title .= $O1." (".$ABI{1}->{"Arch"}.")"." vs ".$O2." (".$ABI{2}->{"Arch"}.")";
        #$Title .= "<br/>";
        #$Title .= "Diff";
        
        $Title .= "Diff:";
        $Title .= "<br/>";
        $Title .= $O1." (".$ABI{1}->{"Arch"}.")";
        $Title .= "<br/>";
        $Title .= $O2." (".$ABI{2}->{"Arch"}.")";
    }
    else
    {
        my $O = $ABI{1}->{"LibraryName"};
        
        if($TargetVersion1)
        {
            $O=~s/(\.so).+\Z/$1/;
            $O .= " ".$TargetVersion1;
        }
        
        $Title .= $O." (".$ABI{1}->{"Arch"}.")";
    }
    
    $Menu .= "<h1 align='center'>$Title</h1>";
    
    $Menu .= "<table cellpadding='0' cellspacing='0'>";
    
    $Menu .= "<tr>";
    
    $Menu .= "<td align='center'>";
    $Menu .= "<h1 class='tool'><a href='".$HomePage."' class='tool'>ABI<br/>Viewer</a></h1>";
    $Menu .= "</td>";
    
    $Menu .= "<td width='40px'>";
    $Menu .= "</td>";
    
    $Menu .= "<td>";
    $Menu .= "<a class='menu' href='".$UrlPr."symbols.html'>Symbols</a>";
    $Menu .= "</td>";
    
    $Menu .= "<td>";
    $Menu .= "<a class='menu' href='".$UrlPr."types.html'>Types</a>";
    $Menu .= "</td>";
    
    if(not $Diff and -f $EXTRA{1}."/debug/elf-info")
    {
        $Menu .= "<td>";
        $Menu .= "<a class='menu' href='".$UrlPr."live-readelf.html'>Live Readelf</a>";
        $Menu .= "</td>";
    }
    
    #$Menu .= "<td width='50px'>";
    #$Menu .= "</td>";
    
    #$Menu .= "<td align='center'>";
    #$Menu .= "<h1 class='tool'>".$ABI{1}->{"LibraryName"}."</h1>";
    #$Menu .= "</td>";
    
    $Menu .= "</tr>";
    $Menu .= "</table>";
    
    $Menu .= "<hr/>";
    #$Menu .= "<h1 align='center'>Object: ".$ABI{1}->{"LibraryName"}."</h1>";
    
    $Menu .= "<br/>";
    $Menu .= "<br/>";
    
    return $Menu;
}

sub showReadelf($)
{
    my $Path = $_[0];
    
    if(not -f $Path) {
        return 0;
    }
    
    printMsg("INFO", "Create live readelf");
    
    my $Readelf = readFile($Path);
    
    my $Content = showMenu("live-readelf");
    
    $Content .= "<h1>Live Readelf</h1>\n";
    
    $Content .= "<br/>\n";
    
    # legend
    $Content .= "<table class='summary symbols_legend'>";
    $Content .= "<tr><td class='func'>FUNC</td><td class='obj'>OBJ</td></tr>";
    $Content .= "<tr><td class='weak'>WEAK</td><td class='global'>GLOBAL</td></tr>";
    $Content .= "</table>";
    
    $Content .= "<div class='summary'>";
    $Content .= "<pre>";
    
    foreach my $Line (split(/\n/, $Readelf))
    {
        $Line=~s&(\sDEFAULT\s+\d+\s+)(\w+)&$1!$2!&g;
        
        $Line=~s&\bFUNC\b&<span class='func'>FUNC</span>&g;
        $Line=~s&\bOBJECT\b&<span class='obj'>OBJECT</span>&g;
        $Line=~s&\bWEAK\b&<span class='weak'>WEAK</span>&g;
        $Line=~s&\bGLOBAL\b&<span class='global'>GLOBAL</span>&g;
        
        if($Line=~/\!(\w+)\!/)
        {
            my $Symbol = $1;
            my $SName = $Symbol;
            
            $SName=~s/[\@]+.+//g;
            
            my $Skip = 0;
            if(defined $SkipStd and isStd($Symbol)) {
                $Skip = 1;
            }
            
            if(defined $SymbolID{1}{$SName} and not $Skip) {
                $Line=~s&!(\w+)!&<a href=\'symbols/$SName.html\'>$Symbol</a>&g;
            }
            else {
                $Line=~s&!(\w+)!&$Symbol&g;
            }
        }
        
        $Content .= $Line."\n";
    }
    
    $Content .= "</pre>";
    $Content .= "</div>";
    
    # document
    $Content = composeHTML_Head("Live Readelf", $ABI{1}->{"LibraryName"}.", readelf, binary, symbols, attributes", $ABI{1}->{"LibraryName"}.": Highlighted readelf output", getTop("live-readelf"), "report.css", "sort.js")."<body>\n".$Content;
    
    if($SHOW_DEV) {
        $Content .= getSign();
    }
    
    $Content .= "</body>\n";
    $Content .= "</html>\n";
    
    writeFile($Output."/live-readelf.html", $Content);
}

sub getSign()
{
    my $Sign = "";
    
    $Sign .= "<br/>\n";
    $Sign .= "<br/>\n";
    
    $Sign .= "<hr/>\n";
    $Sign .= "<div align='right'><a class='home' href='".$HomePage."'>Andrey Ponomarenko's ABI laboratory</a></div>\n";
    
    $Sign .= "<br/>\n";
    
    return $Sign;
}

sub get_Charge($)
{
    my $Symbol = $_[0];
    
    if($Symbol=~/\A_Z/)
    {
        if($Symbol=~/C1[EI]/) {
            return "[in-charge]";
        }
        elsif($Symbol=~/C2[EI]/) {
            return "[not-in-charge]";
        }
        elsif($Symbol=~/D1[EI]/) {
            return "[in-charge]";
        }
        elsif($Symbol=~/D2[EI]/) {
            return "[not-in-charge]";
        }
        elsif($Symbol=~/D0[EI]/) {
            return "[in-charge-deleting]";
        }
    }
    
    return undef;
}

sub rmQual($)
{
    my $Name = $_[0];
    $Name=~s/\A(class|struct|union|enum) //;
    
    return $Name;
}

sub showTypeInfo($$)
{
    my ($TID, $VN) = @_;
    my %TInfo = %{$ABI{$VN}->{"TypeInfo"}{$TID}};
    
    if(keys(%TInfo)<=2)
    { # incomplete info
        return;
    }
    
    if(isPrivateABI($TID, $VN)) {
        return;
    }
    
    my $TID_N = undef;
    my %TInfo_N = undef;
    
    my $Compare = compareType($TID, $VN);
    
    if($Compare)
    {
        $TID_N = $MappedType{$TID};
        %TInfo_N = %{$ABI{2}->{"TypeInfo"}{$TID_N}};
    }
    
    my $TName = $TInfo{"Name"};
    my $TType = $TInfo{"Type"};
    my $NameSpace = $TInfo{"NameSpace"};
    
    my $Source = $TInfo{"Source"};
    if(not $Source) {
        $Source = $TInfo{"Header"};
    }
    
    if($NameSpace) {
        $TName=~s/\b\Q$NameSpace\E\:\://g;
    }
    $TName = rmQual($TName);
    
    my $Content = "";
    my $Contents = "<table class='contents'>";
    $Contents .= "<tr><td><b>Contents</b></td></tr>";
    $Contents .= "<tr><td><a href='#Info'>Info</a></td></tr>";
    
    if($TType=~/Class|Struct|Union|Enum/ and defined $TInfo{"Memb"})
    {
        my $Legend = "";
        $Legend .= "<table class='summary stack_legend' cellpadding='0' cellspacing='0'>";
        $Legend .= "<tr><td class='padding'>PADDING</td><td class='stack_param'>FIELD</td></tr>";
        
        if($TType=~/Class/) {
            $Legend .= "<tr><td class='mem_vtable'>V-TABLE</td><td class='stack_data'>BASE</td></tr>";
        }
        
        $Legend .= "<tr><td class='bitfield'>BIT-FIELD</td><td></td></tr>";
        
        $Legend .= "</table>";
        $Legend .= "<br/>";
        $Legend .= "<br/>";
        
        # Fields
        $Content .= "<h2 id='Fields'>Fields</h2>\n";
        
        if(defined $Diff)
        {
            $Content .= "<table cellpadding='0' cellspacing='0'>\n";
            $Content .= "<tr>\n";
            
            $Content .= "<td valign='top'>\n";
            $Content .= $Legend;
            $Content .= "</td>\n";
            
            $Content .= "<td width='20px;'>\n";
            $Content .= "</td>\n";
            
            $Content .= "<td valign='top'>\n";
            # legend
            $Content .= "<table class='summary symbols_legend'>";
            $Content .= "<tr><td class='added'>ADDED</td></tr>";
            $Content .= "<tr><td class='removed'>REMOVED</td></tr>";
            # $Content .= "<tr><td class='changed'>CHANGED</td></tr>";
            $Content .= "</table>";
            $Content .= "</td>\n";
            
            $Content .= "</tr>\n";
            $Content .= "</table>\n";
            # $Content .= "<br/>\n";
        }
        else
        {
            $Content .= $Legend;
        }
        
        $Content .= showFields($TID, $VN);
        $Content .= "<br/>\n";
        $Content .= "<br/>";
        $Contents .= "<tr><td><a href='#Fields'>Fields</a></td></tr>\n";
    }
    
    if($TType=~/Class|Struct|Union/ and (defined $TInfo{"Memb"} or defined $TInfo{"Base"}))
    {
        # Layout
        $Content .= "<h2 id='Layout'>Memory Layout</h2>\n";
        
        if(defined $TID_N)
        {
            if($TInfo{"Type"} eq "Union")
            {
                $Content .= "<table cellpadding='0' cellspacing='0'>\n";
                
                $Content .= "<tr>\n";
                $Content .= "<td align='left' class='title'>Old</td>\n";
                $Content .= "</tr>\n";
                
                $Content .= "<tr>\n";
                $Content .= "<td valign='top'>\n";
                $Content .= showUnionLayout($TID, $VN);
                $Content .= "</td>\n";
                $Content .= "</tr>\n";
                
                $Content .= "<tr>\n";
                $Content .= "<td height='40px'></td>\n";
                $Content .= "</tr>\n";
                
                $Content .= "<tr>\n";
                $Content .= "<td align='left' class='title'>New</td>\n";
                $Content .= "</tr>\n";
                
                $Content .= "<tr>\n";
                $Content .= "<td valign='top'>\n";
                $Content .= showUnionLayout($TID_N, 2);
                $Content .= "</td>\n";
                $Content .= "</tr>\n";
                
                $Content .= "</tr>\n";
                $Content .= "</table>\n";
            }
            else
            {
                $Content .= "<table cellpadding='0' cellspacing='0'>\n";
                
                $Content .= "<tr>\n";
                $Content .= "<td align='center' class='title'>Old</td>\n";
                $Content .= "<td width='40px'></td>\n";
                $Content .= "<td align='center' class='title'>New</td>\n";
                $Content .= "</tr>\n";
                
                $Content .= "<tr>\n";
                
                $Content .= "<td valign='top'>\n";
                $Content .= showMemoryLayout($TID, $VN);
                $Content .= "</td>\n";
                
                $Content .= "<td></td>\n";
                
                $Content .= "<td valign='top'>\n";
                $Content .= showMemoryLayout($TID_N, 2);
                $Content .= "</td>\n";
                
                $Content .= "</tr>\n";
                $Content .= "</table>\n";
            }
        }
        else
        {
            if($TInfo{"Type"} eq "Union") {
                $Content .= showUnionLayout($TID, $VN);
            }
            else {
                $Content .= showMemoryLayout($TID, $VN);
            }
        }
        $Content .= "<br/>\n";
        $Content .= "<br/>";
        $Contents .= "<tr><td><a href='#Layout'>Memory Layout</a></td></tr>\n";
    }
    
    $Contents .= "</table>";
    $Contents .= "<br/>\n";
    
    my $Summary = "";
    
    $Summary .= "<h2 id='Info'>Info</h2>\n";
    $Summary .= "<table cellpadding='3' class='summary short'>\n";
    
    $Summary .= "<tr>\n";
    $Summary .= "<th>Name</th>\n";
    $Summary .= "<td>".htmlSpecChars($TName)."</td>";
    $Summary .= "</tr>\n";
    
    $Summary .= "<tr>\n";
    $Summary .= "<th>Type</th>\n";
    if($TType=~/Class|Struct|Union|Enum/) {
        $Summary .= "<td class='".lc($TType)."'>".uc($TType)."</td>";
    }
    else {
        $Summary .= "<td class='other_type'>".uc($TType)."</td>";
    }
    
    $Summary .= "</tr>\n";
    
    # total fields
    if($TType=~/Class|Struct|Union|Enum/)
    {
        if(defined $TInfo{"Memb"})
        {
            $Summary .= "<tr>\n";
            $Summary .= "<th>Fields</th>\n";
            $Summary .= "<td><a href='#Fields'>".keys(%{$TInfo{"Memb"}})."</a></td>\n";
            $Summary .= "</tr>\n";
        }
        elsif($Source)
        {
            $Summary .= "<tr>\n";
            $Summary .= "<th>Fields</th>\n";
            $Summary .= "<td>0</td>\n";
            $Summary .= "</tr>\n";
        }
    }
    
    # source
    if($Source)
    {
        $Summary .= "<tr>\n";
        $Summary .= "<th>Source</th>\n";
        $Summary .= "<td>$Source</td>\n";
        $Summary .= "</tr>\n";
    }
    
    # namespace
    if($NameSpace)
    {
        $Summary .= "<tr>\n";
        $Summary .= "<th>Namespace</th>\n";
        $Summary .= "<td>".htmlSpecChars($NameSpace)."</td>\n";
        $Summary .= "</tr>\n";
    }
    
    if($TInfo{"Size"})
    {
        $Summary .= "<tr>\n";
        $Summary .= "<th>Size</th>\n";
        if(defined $Diff and defined $TID_N
        and $TInfo{"Size"} ne $TInfo_N{"Size"}) {
            $Summary .= "<td><span class='replace'>".$TInfo{"Size"}."</span> ".$TInfo_N{"Size"}."</td>\n";
        }
        else {
            $Summary .= "<td>".$TInfo{"Size"}."</td>\n";
        }
        $Summary .= "</tr>\n";
    }
    
    if(defined $TInfo{"Base"})
    {
        $Summary .= "<tr>\n";
        $Summary .= "<th>Base class</th>\n";
        $Summary .= "<td>";
        $Summary .= showBaseClasses($TID, $VN);
        $Summary .= "</td>";
        $Summary .= "</tr>\n";
    }
    elsif(defined $TInfo{"BaseType"})
    {
        $Summary .= "<tr>\n";
        $Summary .= "<th>Base type</th>\n";
        $Summary .= "<td>";
        $Summary .= showType($TInfo{"BaseType"}, $VN, "", $TID);
        $Summary .= "</td>";
        $Summary .= "</tr>\n";
    }
    
    if($TType=~/Class|Struct|Union|Enum|FuncPtr|MethodPtr/)
    {
        if(my $Usage = showUsage($TID, $VN))
        {
            $Summary .= "<tr>\n";
            $Summary .= "<th>Usage</th>\n";
            $Summary .= "<td>".$Usage."</td>\n";
            $Summary .= "</tr>\n";
        }
    }
    
    if(defined $Diff)
    {
        # status
        $Summary .= "<tr>\n";
        $Summary .= "<th>Status</th>\n";
        if(defined $AddedTypes_All{$TInfo{"Name"}}) {
            $Summary .= "<td class='added'>ADDED</td>\n";
        }
        elsif(defined $RemovedTypes_All{$TInfo{"Name"}}) {
            $Summary .= "<td class='removed'>REMOVED</td>\n";
        }
        elsif(defined $ChangedTypes{$TInfo{"Name"}}) {
            $Summary .= "<td class='changed'>CHANGED</td>\n";
        }
        else {
            $Summary .= "<td>UNCHANGED</td>\n";
        }
        $Summary .= "</tr>\n";
    }
    
    $Summary .= "</table>\n";
    $Summary .= "<br/>\n";
    $Summary .= "<br/>\n";
    
    $Content = $Summary.$Content;
    
    my $Title = "Type";
    if(defined $AddedTypes_All{$TInfo{"Name"}}) {
        $Title = "Added ".$Title;
    }
    elsif(defined $RemovedTypes_All{$TInfo{"Name"}}) {
        $Title = "Removed ".$Title;
    }
    elsif(defined $ChangedTypes{$TInfo{"Name"}}) {
        $Title = "Changed ".$Title;
    }
    
    my $Head = showMenu("type");
    $Head .= "<h1 style='max-width:1024px; word-wrap:break-word;'>$Title:&nbsp;".htmlSpecChars(rmQual($TInfo{"Name"}))."</h1>\n";
    $Head .= "<br/>\n";
    $Head .= $Contents;
    
    $Content = $Head.$Content;
    
    # document
    my $HtmlName = htmlSpecChars($TInfo{"Name"}, 1);
    my $D = "";
    my @K = ($HtmlName);
    if($TInfo{"Type"}=~/Struct|Class|Union/)
    {
        $D = "Fields and memory layout";
        push(@K, "fields, layout, memory, offset, size, usage");
    }
    elsif($TInfo{"Type"} eq "Enum")
    {
        $D = "Fields and values";
        push(@K, "fields, values, usage");
    }
    $Content = composeHTML_Head("Type: $HtmlName", join(", ", @K), $D, getTop("type"), "report.css", "sort.js")."<body>\n".$Content;
    
    if($SHOW_DEV) {
        $Content .= getSign();
    }
    
    $Content .= "</body>\n";
    $Content .= "</html>\n";
    
    writeFile($Output."/types/".getUname_T($TID, $VN).".html", $Content);
}

sub showSymbolInfo($$)
{
    my ($ID, $VN) = @_;
    
    my %Info = %{$ABI{$VN}->{"SymbolInfo"}{$ID}};
    
    my $Symbol = $Info{"MnglName"};
    if(not $Symbol) {
        $Symbol = $Info{"ShortName"};
    }
    
    if(defined $SkipStd and isStd($Symbol)) {
        next;
    }
    
    if(not $Info{"Bind"}) {
        next;
    }
    
    my $ID_N = undef;
    if(compareSymbol($Symbol, $VN)) {
        $ID_N = $SymbolID{2}{$Symbol};
    }
    
    my $Sig = get_Signature(\%Info, $VN, 1, 0, undef);
    
    my $CId = $Info{"Class"};
    my $Class = "";
    my $NameSpace = "";
    
    if($CId)
    {
        $Class = $ABI{$VN}->{"TypeInfo"}{$CId}{"Name"};
        $NameSpace = $ABI{$VN}->{"TypeInfo"}{$CId}{"NameSpace"};
    }
    
    my $Kind = $Info{"Kind"};
    
    if($NameSpace) {
        $Class=~s/\b\Q$NameSpace\E\:\://g;
    }
    
    my $Content = "";
    
    my $Contents = "<table class='contents'>";
    $Contents .= "<tr><td><b>Contents</b></td></tr>";
    $Contents .= "<tr><td><a href='#Info'>Info</a></td></tr>";
    
    # $Content .= "<br/>\n";
    
    if($Kind eq "FUNC")
    {
        my $Legend = "";
        $Legend .= "<table class='summary stack_legend' cellpadding='0' cellspacing='0'>";
        $Legend .= "<tr><td class='padding'>PADDING</td><td class='stack_param'>PARAM</td></tr><tr><td class='stack_data'>LOCAL</td><td class='stack_return'>RETURN</td></tr>";
        $Legend .= "</table>";
        $Legend .= "<br/>";
        $Legend .= "<br/>";
        
        # Parameters
        $Content .= "<h2 id='CallSeq'>Calling sequence</h2>\n";
        
        if(defined $Diff)
        {
            $Content .= "<table cellpadding='0' cellspacing='0'>\n";
            $Content .= "<tr>\n";
            
            $Content .= "<td valign='top'>\n";
            $Content .= $Legend;
            $Content .= "</td>\n";
            
            $Content .= "<td width='20px;'>\n";
            $Content .= "</td>\n";
            
            $Content .= "<td valign='top'>\n";
            
            $Content .= "<table class='summary symbols_legend'>";
            $Content .= "<tr><td class='added'>ADDED</td></tr>";
            $Content .= "<tr><td class='removed'>REMOVED</td></tr>";
            $Content .= "</table>";
            $Content .= "</td>\n";
            
            $Content .= "</tr>\n";
            $Content .= "</table>\n";
        }
        else
        {
            $Content .= $Legend;
        }
        
        $Content .= showCallingSequence($ID, $VN);
        $Content .= "<br/>\n";
        $Contents .= "<tr><td><a href='#CallSeq'>Calling sequence</a></td></tr>\n";
        $Content .= "<br/>";
        
        # Stack Frame
        $Content .= "<h2 id='StackFrame'>Stack frame layout</h2>\n";
        
        
        if(defined $ID_N)
        {
            $Content .= "<table cellpadding='0' cellspacing='0'>\n";
            
            $Content .= "<tr>\n";
            $Content .= "<td align='center' class='title'>Old</td>\n";
            $Content .= "<td width='40px'></td>\n";
            $Content .= "<td align='center' class='title'>New</td>\n";
            $Content .= "</tr>\n";
            
            $Content .= "<tr>\n";
            
            $Content .= "<td valign='top'>\n";
            $Content .= showStackFrame($ID, $VN);
            $Content .= "</td>\n";
            
            $Content .= "<td></td>\n";
            
            $Content .= "<td valign='top'>\n";
            $Content .= showStackFrame($ID_N, 2);
            $Content .= "</td>\n";
            
            $Content .= "</tr>\n";
            $Content .= "</table>\n";
        }
        else
        {
            $Content .= showStackFrame($ID, $VN);
        }
        
        
        $Content .= "<br/>\n";
        $Contents .= "<tr><td><a href='#StackFrame'>Stack frame layout</a></td></tr>\n";
        $Content .= "<br/>";
        
        # Used registers
        $Content .= "<h2 id='Registers'>Registers usage</h2>\n";
        
        if(defined $ID_N)
        {
            $Content .= "<table cellpadding='0' cellspacing='0'>\n";
            
            $Content .= "<tr>\n";
            $Content .= "<td align='center' class='title'>Old</td>\n";
            $Content .= "<td width='40px'></td>\n";
            $Content .= "<td align='center' class='title'>New</td>\n";
            $Content .= "</tr>\n";
            
            $Content .= "<tr>\n";
            
            $Content .= "<td valign='top'>\n";
            $Content .= showRegisters($ID, $VN);
            $Content .= "</td>\n";
            
            $Content .= "<td></td>\n";
            
            $Content .= "<td valign='top'>\n";
            $Content .= showRegisters($ID_N, 2);
            $Content .= "</td>\n";
            
            $Content .= "</tr>\n";
            $Content .= "</table>\n";
        }
        else
        {
            $Content .= showRegisters($ID, $VN);
        }
        
        $Content .= "<br/>\n";
        $Contents .= "<tr><td><a href='#Registers'>Registers usage</a></td></tr>\n";
        $Content .= "<br/>";
    }
    
    if($Kind=~/OBJ/ and isVTable($Symbol)
    and $CId and defined $ABI{$VN}->{"TypeInfo"}{$CId}{"VTable"})
    { # v-table
        $Content .= "<h2 id='VTable'>V-table</h2>\n";
        $Content .= showVTable($CId, $VN);
        $Content .= "<br/>\n";
        $Contents .= "<tr><td><a href='#VTable'>V-table</a></td></tr>\n";
        $Content .= "<br/>";
    }
    
    $Content .= "<br/>";
    $Content .= "<br/>";
    
    $Contents .= "</table>";
    $Contents .= "<br/>\n";
    
    my $Summary = "";
    
    $Summary .= "<h2 id='Info'>Info</h2>\n";
    $Summary .= "<table cellpadding='3' class='summary short'>\n";
    
    # unmangled
    $Summary .= "<tr>\n";
    $Summary .= "<th>Signature</th>\n";
    $Summary .= "<td>\n".$Sig."</td>\n";
    $Summary .= "</tr>\n";
    
    # type
    if($Kind eq "OBJECT") {
        $Kind = "OBJ";
    }
    my $SubKind = "";
    if($Info{"Constructor"}) {
        $SubKind = " / C-tor ".get_Charge($Symbol);
    }
    elsif($Info{"Destructor"}) {
        $SubKind = " / D-tor ".get_Charge($Symbol);
    }
    elsif($Info{"Static"}) {
        $SubKind = " / [static]";
    }
    elsif($Info{"Const"}) {
        $SubKind = " / [const]";
    }
    elsif(isVTable($Symbol)) {
        $SubKind = " / V-table";
    }
    
    $Summary .= "<tr>\n";
    $Summary .= "<th>Type</th>\n";
    $Summary .= "<td class='".lc($Kind)."'>$Kind$SubKind</td>";
    $Summary .= "</tr>\n";
    
    # source
    my $Source = $Info{"Source"};
    if(not $Source) {
        $Source = $Info{"Header"};
    }
    $Summary .= "<tr>\n";
    $Summary .= "<th>Source</th>\n";
    $Summary .= "<td>$Source</td>\n";
    $Summary .= "</tr>\n";
    
    # class and namespace
    if($Class)
    {
        if($NameSpace)
        {
            $Summary .= "<tr>\n";
            $Summary .= "<th>Namespace</th>\n";
            $Summary .= "<td>".htmlSpecChars($NameSpace)."</td>\n";
            $Summary .= "</tr>\n";
        }
        
        $Summary .= "<tr>\n";
        $Summary .= "<th>Class</th>\n";
        $Summary .= "<td><a href='../types/".getUname_T($CId, $VN).".html'>".htmlSpecChars($Class)."</a></td>\n";
        $Summary .= "</tr>\n";
    }
    
    # params
    my $PNum = 0;
    if(defined $Info{"Param"})
    {
        $PNum = keys(%{$Info{"Param"}});
        if(defined $Info{"Class"}
        and not defined $Info{"Static"}) {
            $PNum-=1;
        }
    }
    
    if($Kind ne "OBJ")
    {
        $Summary .= "<tr>\n";
        $Summary .= "<th>Params</th>\n";
        if($PNum) {
            $Summary .= "<td><a href='#CallSeq'>".$PNum."</a></td>\n";
        }
        else {
            $Summary .= "<td>0</td>\n";
        }
        $Summary .= "</tr>\n";
    }
    
    # return
    my $Rid = $Info{"Return"};
    if($Rid)
    {
        $Summary .= "<tr>\n";
        $Summary .= "<th>Return</th>\n";
        $Summary .= "<td>".showType($Rid, $VN, $ID)."</td>\n";
        $Summary .= "</tr>\n";
    }
    
    # value
    my $Val = $Info{"Val"};
    if(length($Val)==16) {
        $Val=~s/\A00000000//g
    }
    # $Summary .= "<tr>\n";
    # $Summary .= "<th>Val</th>\n";
    # $Summary .= "<td>".$Val."</td>\n";
    # $Summary .= "</tr>\n";
    
    # size
    $Summary .= "<tr>\n";
    $Summary .= "<th>Size</th>\n";
    $Summary .= "<td>".$Info{"Size"}."</td>\n";
    $Summary .= "</tr>\n";
    
    # bind
    $Summary .= "<tr>\n";
    $Summary .= "<th>Bind</th>\n";
    $Summary .= "<td class='".lc($Info{"Bind"})."'>".$Info{"Bind"}."</td>\n";
    $Summary .= "</tr>\n";
    
    # vis
    $Summary .= "<tr>\n";
    $Summary .= "<th>Vis</th>\n";
    $Summary .= "<td>".$Info{"Vis"}."</td>\n";
    $Summary .= "</tr>\n";
    
    # ndx
    $Summary .= "<tr>\n";
    $Summary .= "<th>Ndx</th>\n";
    $Summary .= "<td>".$Info{"Ndx"}."</td>\n";
    $Summary .= "</tr>\n";
    
    if(defined $Diff)
    {
        # status
        $Summary .= "<tr>\n";
        $Summary .= "<th>Status</th>\n";
        if(defined $AddedSymbols{$Symbol}) {
            $Summary .= "<td class='added'>ADDED</td>\n";
        }
        elsif(defined $RemovedSymbols{$Symbol}) {
            $Summary .= "<td class='removed'>REMOVED</td>\n";
        }
        elsif(defined $ChangedSymbols{$Symbol}) {
            $Summary .= "<td class='changed'>CHANGED</td>\n";
        }
        else {
            $Summary .= "<td>UNCHANGED</td>\n";
        }
        $Summary .= "</tr>\n";
    }
    
    $Summary .= "</table>\n";
    
    $Summary .= "<br/>\n";
    $Summary .= "<br/>";
    
    $Content = $Summary.$Content;
    
    my $Title = "Symbol";
    if(defined $AddedSymbols{$Symbol}) {
        $Title = "Added ".$Title;
    }
    elsif(defined $RemovedSymbols{$Symbol}) {
        $Title = "Removed ".$Title;
    }
    elsif(defined $ChangedSymbols{$Symbol}) {
        $Title = "Changed ".$Title;
    }
    
    my $Head = showMenu("symbol");
    $Head .= "<h1 style='max-width:1024px; word-wrap:break-word;'>$Title:&nbsp;$Symbol</h1>\n";
    $Head .= "<br/>\n";
    $Head .= $Contents;
    
    $Content = $Head.$Content;
    
    my $K = "stack frame, registers, layout, parameters, offset";
    my $D = "Stack frame layout and used registers";
    
    if($Kind eq "OBJ")
    {
        if(isVTable($Symbol))
        {
            $K = "virtual table, layout";
            $D = "Virtual table layout";
        }
        else
        {
            $K = "global data, attributes";
            $D = "Attributes of global data";
        }
    }
    
    # document
    $Content = composeHTML_Head("Symbol: ".$Symbol, $Symbol.", ".$K, $D, getTop("symbol"), "report.css", "sort.js")."<body>\n".$Content;
    
    if($SHOW_DEV) {
        $Content .= getSign();
    }
    
    $Content .= "</body>\n";
    $Content .= "</html>\n";
    
    writeFile($Output."/symbols/$Symbol.html", $Content);
}

sub get_PureType($$) {
    return get_BaseType($_[0], $_[1], "Const|Volatile|ConstVolatile|Restrict|Typedef");
}

sub get_BaseType($$$)
{
    my ($Tid, $ABIP, $Qual) = @_;
    
    if(defined $ABIP->{"TypeInfo"}{$Tid}
    and defined $ABIP->{"TypeInfo"}{$Tid}{"BaseType"})
    {
        my $TType = $ABIP->{"TypeInfo"}{$Tid}{"Type"};
        my $BTid = $ABIP->{"TypeInfo"}{$Tid}{"BaseType"};
        
        if($TType=~/$Qual/) {
            return get_BaseType($BTid, $ABIP, $Qual);
        }
    }
    
    return $Tid;
}

sub get_BasicType($$)
{
    my ($Tid, $VN) = @_;
    
    return get_BaseType($Tid, $ABI{$VN}, "Const|Volatile|ConstVolatile|Restrict|Typedef|Ref|RvalueRef|Array|Pointer");
}

sub getTypeName($$)
{
    my ($Tid, $VN) = @_;
    return $ABI{$VN}->{"TypeInfo"}{$Tid}{"Name"};
}

sub mergeEnums($$)
{
    my ($ID1, $ID2) = @_;
    
    my %Info1 = %{$ABI{1}->{"TypeInfo"}{$ID1}};
    my %Info2 = %{$ABI{2}->{"TypeInfo"}{$ID2}};
    
    my %NamePos1 = ();
    my %NamePos2 = ();
    my %ValuePos2 = ();
    
    my %Mapped = ();
    my %Mapped_R = ();
    
    foreach my $P (sort {int($a)<=>int($b)} keys(%{$Info1{"Memb"}}))
    {
        $NamePos1{$Info1{"Memb"}{$P}{"name"}} = $P;
    }
    
    foreach my $P (sort {int($a)<=>int($b)} keys(%{$Info2{"Memb"}}))
    {
        $NamePos2{$Info2{"Memb"}{$P}{"name"}} = $P;
        $ValuePos2{$Info2{"Memb"}{$P}{"value"}} = $P;
    }
    
    # match by name or value
    foreach my $P (sort {int($a)<=>int($b)} keys(%{$Info1{"Memb"}}))
    {
        my $MName = $Info1{"Memb"}{$P}{"name"};
        
        if(defined $NamePos2{$MName})
        {
            $Mapped{$P} = $NamePos2{$MName};
            $Mapped_R{$NamePos2{$MName}} = $P;
        }
    }
    
    foreach my $P (sort {int($a)<=>int($b)} keys(%{$Info1{"Memb"}}))
    {
        my $MVal = $Info1{"Memb"}{$P}{"value"};
        
        if(defined $ValuePos2{$MVal})
        {
            my $P2 = $ValuePos2{$MVal};
            my $MName2 = $Info2{"Memb"}{$P2}{"name"};
            
            if(not defined $NamePos1{$MName2})
            {
                $Mapped{$P} = $P2;
                $Mapped_R{$P2} = $P;
            }
        }
    }
    
    foreach my $P (sort {int($a)<=>int($b)} keys(%{$Info1{"Memb"}}))
    {
        if(not defined $Mapped{$P}) {
            $ChangeStatus{"T"}{1}{$ID1}{$P}{"Removed"} = 1;
        }
    }
    
    foreach my $P (sort {int($a)<=>int($b)} keys(%{$Info2{"Memb"}}))
    {
        if(not defined $Mapped_R{$P}) {
            $ChangeStatus{"T"}{2}{$ID2}{$P}{"Added"} = 1;
        }
    }
    
    foreach my $P (sort keys(%Mapped)) {
        $ChangeStatus{"T"}{1}{$ID1}{$P}{"Mapped"} = $Mapped{$P};
    }
}

sub mergeSets($$$)
{
    my ($ID1, $ID2, $T) = @_;
    
    my $Entry = "TypeInfo";
    my $Elems = "Memb";
    if($T eq "S")
    {
        $Entry = "SymbolInfo";
        $Elems = "Param";
    }
    
    my %Info1 = %{$ABI{1}->{$Entry}{$ID1}};
    my %Info2 = %{$ABI{2}->{$Entry}{$ID2}};
    
    my %NamePos2 = ();
    my %TypePos2 = ();
    
    my %Mapped = ();
    my %Mapped_R = ();
    
    foreach my $P (sort {int($a)<=>int($b)} keys(%{$Info2{$Elems}}))
    {
        my $MTid = $Info2{$Elems}{$P}{"type"};
        my $MTid_P = get_PureType($MTid, $ABI{2});
        
        $NamePos2{$Info2{$Elems}{$P}{"name"}} = $P;
        $TypePos2{getTypeName($MTid_P, 2)}{$P} = 1;
    }
    
    # match by name
    foreach my $P (sort {int($a)<=>int($b)} keys(%{$Info1{$Elems}}))
    {
        my $MName = $Info1{$Elems}{$P}{"name"};
        
        if(defined $NamePos2{$MName})
        {
            $Mapped{$P} = $NamePos2{$MName};
            $Mapped_R{$NamePos2{$MName}} = $P;
        }
    }
    
    # match by type
    foreach my $P (sort {int($a)<=>int($b)} keys(%{$Info1{$Elems}}))
    {
        if(defined $Mapped{$P}) {
            next;
        }
        
        my $MName = $Info1{$Elems}{$P}{"name"};
        my $MTid = $Info1{$Elems}{$P}{"type"};
        my $MTid_P = get_PureType($MTid, $ABI{1});
        
        my %Matched = ();
        foreach my $P2 (keys(%{$TypePos2{getTypeName($MTid_P, 1)}}))
        {
            if(not defined $Mapped_R{$P2})
            {
                $Matched{$P2} = $Info2{$Elems}{$P2}{"name"};
            }
        }
        if(my @Matched = sort {int($a)<=>int($b)} keys(%Matched))
        {
            if($#Matched==0)
            {
                $Mapped{$P} = $Matched[0];
                $Mapped_R{$Matched[0]} = $P;
            }
            else
            {
                @Matched = sort {longestSubstr($MName, $Matched{$b})<=>longestSubstr($MName, $Matched{$a})} @Matched;
                
                $Mapped{$P} = $Matched[0];
                $Mapped_R{$Matched[0]} = $P;
            }
        }
    }
    
    my %Removed = ();
    my %Added = ();
    
    foreach my $P (sort {int($a)<=>int($b)} keys(%{$Info1{$Elems}}))
    {
        if(not defined $Mapped{$P}) {
            $Removed{$P} = 1;
        }
    }
    
    foreach my $P (sort {int($a)<=>int($b)} keys(%{$Info2{$Elems}}))
    {
        if(not defined $Mapped_R{$P}) {
            $Added{$P} = 1;
        }
    }
    
    foreach my $P (sort keys(%Mapped))
    {
        my $To = $Mapped{$P};
        $ChangeStatus{$T}{1}{$ID1}{$P}{"Mapped"} = $To;
        $ChangeStatus{$T}{2}{$ID2}{$To}{"Mapped"} = $P;
    }
    
    foreach my $P (sort keys(%Removed)) {
        $ChangeStatus{$T}{1}{$ID1}{$P}{"Removed"} = 1;
    }
    
    foreach my $P (sort keys(%Added)) {
        $ChangeStatus{$T}{2}{$ID2}{$P}{"Added"} = 1;
    }
    
    my $MC = 0;
    my $RC = 0;
    
    foreach my $P (sort {int($a)<=>int($b)} keys(%{$Info2{$Elems}}))
    {
        $ChangeStatus{$T}{2}{$ID2}{$P}{"Mapped_Rel"} = $MC;
        
        if(defined $Mapped_R{$P})
        {
            my $P1 = $Mapped_R{$P};
            foreach my $PP1 (0 .. $P1 - 1)
            {
                if(defined $Removed{$PP1})
                {
                    $ChangeStatus{$T}{2}{$ID2}{$P}{"Mapped_Rel"} += 1;
                }
            }
            
            $MC += 1;
        }
    }
}

sub longestSubstr($$)
{
    my ($S1, $S2) = @_;
    
    my $Len1 = length($S1);
    my $Len2 = length($S2);
    
    if($Len1>$Len2)
    {
        my $S = $S2;
        $S2 = $S1;
        $S1 = $S;
    }
    
    if(index($S2, $S1)!=-1) {
        return $Len1;
    }
    
    foreach my $P (0 .. $Len1-1)
    {
        my $L = $Len1 - $P;
        
        foreach my $SP (0 .. $Len1-$L)
        {
            my $Substr = substr($S1, $SP, $L);
            
            if(index($S2, $Substr)!=-1)
            {
                return $L;
            }
        }
    }
    
    return 0;
}

sub compareType($$)
{
    my ($TID, $VN) = @_;
    
    if(defined $Diff and $VN==1 and defined $MappedType{$TID})
    {
        my $Info = $ABI{2}->{"TypeInfo"}{$MappedType{$TID}};
        
        if(keys(%{$Info})>2)
        {
            return 1;
        }
    }
    
    return 0;
}

sub compareSymbol($$)
{
    my ($Symbol, $VN) = @_;
    return (defined $Diff and $VN==1 and not defined $AddedSymbols{$Symbol}
    and not defined $RemovedSymbols{$Symbol});
}

sub showFields($$)
{
    my ($TID, $VN) = @_;
    my %TInfo = %{$ABI{$VN}->{"TypeInfo"}{$TID}};
    
    my $Compare = compareType($TID, $VN);
    my $TID_N = undef;
    my %TInfo_N = ();
    
    if($Compare)
    {
        $TID_N = $MappedType{$TID};
        %TInfo_N = %{$ABI{2}->{"TypeInfo"}{$TID_N}};
        
        if($TInfo{"Type"} eq "Enum") {
            mergeEnums($TID, $TID_N);
        }
        else {
            mergeSets($TID, $TID_N, "T");
        }
    }
    
    my $Content = "<table cellpadding='3' class='summary'>\n";
    
    $Content .= "<tr>";
    if($TInfo{"Type"} eq "Enum")
    {
        $Content .= "<th>Name</th>";
        $Content .= "<th>Value</th>";
    }
    else
    {
        $Content .= "<th>Pos</th>";
        $Content .= "<th>Name</th>";
        $Content .= "<th>Type</th>";
        $Content .= "<th>Size</th>";
        $Content .= "<th>Offset</th>";
    }
    $Content .= "</tr>\n";
    
    my $MC = 0;
    foreach my $Pos (sort {int($a)<=>int($b)} keys(%{$TInfo{"Memb"}}))
    {
        if(defined $ChangeStatus{"T"}{2}{$TID_N}{$Pos + $MC}{"Added"})
        {
            $ChangedTypes{$TInfo{"Name"}} = 1;
            while(defined $ChangeStatus{"T"}{2}{$TID_N}{$Pos + $MC}{"Added"})
            {
                $Content .= showField($TID_N, 2, $Pos + $MC, 0);
                $MC += 1;
            }
        }
        elsif(defined $ChangeStatus{"T"}{1}{$TID}{$Pos}{"Removed"})
        {
            $ChangedTypes{$TInfo{"Name"}} = 1;
            $MC -= 1;
        }
        
        $Content .= showField($TID, $VN, $Pos, $Compare);
    }
    
    if(defined $TID_N)
    {
        foreach my $Pos (sort {int($a)<=>int($b)} keys(%{$TInfo_N{"Memb"}}))
        {
            if($Pos>keys(%{$TInfo{"Memb"}}) - 1 + $MC)
            {
                if(defined $ChangeStatus{"T"}{2}{$TID_N}{$Pos}{"Added"})
                {
                    $ChangedTypes{$TInfo{"Name"}} = 1;
                    $Content .= showField($TID_N, 2, $Pos, 0);
                }
            }
        }
    }
    
    $Content .= "</table>";
    
    return $Content;
}

sub showField($$$$)
{
    my ($TID, $VN, $Pos, $Compare) = @_;
    my $TInfo = $ABI{$VN}->{"TypeInfo"}{$TID};
    
    my $TID_N = undef;
    my $TInfo_N = undef;
    
    if($Compare)
    {
        $TID_N = $MappedType{$TID};
        $TInfo_N = $ABI{2}->{"TypeInfo"}{$TID_N};
    }
    
    my %MInfo = %{$TInfo->{"Memb"}{$Pos}};
    my $MTid = $MInfo{"type"};
    my $MName = $MInfo{"name"};
    
    my $Pos_N = undef;
    my $Pos_R_N = undef;
    
    my %MInfo_N = ();
    my $MTid_N = undef;
    my $MName_N = undef;
    
    if($Compare)
    {
        if(defined $ChangeStatus{"T"}{1}{$TID}{$Pos}{"Mapped"})
        {
            $Pos_N = $ChangeStatus{"T"}{1}{$TID}{$Pos}{"Mapped"};
            $Pos_R_N = $ChangeStatus{"T"}{2}{$TID_N}{$Pos_N}{"Mapped_Rel"};
        }
        
        if(defined $Pos_N)
        {
            %MInfo_N = %{$TInfo_N->{"Memb"}{$Pos_N}};
            $MTid_N = $MInfo_N{"type"};
            $MName_N = $MInfo_N{"name"};
        }
    }
    
    my $StatusClass = "";
    my $Added = undef;
    
    if(defined $ChangeStatus{"T"}{$VN}{$TID}{$Pos}{"Added"})
    {
        $StatusClass = " class='added'";
        $Added = 1;
    }
    elsif(defined $ChangeStatus{"T"}{$VN}{$TID}{$Pos}{"Removed"})
    {
        $StatusClass = " class='removed'";
    }
    
    my $Content = "<tr>";
    if($TInfo->{"Type"} eq "Enum")
    {
        my $MVal = $MInfo{"value"};
        my $MVal_N = undef;
        
        if(defined $Pos_N) {
            $MVal_N = $MInfo_N{"value"};
        }
        
        my $SMName = $MName;
        if(defined $Pos_N and $MName ne $MName_N)
        {
            $ChangedTypes{$TInfo->{"Name"}} = 1;
            $SMName = "<span class='replace'>$MName</span> $MName_N";
        }
        
        $Content .= "<td$StatusClass><span class='field'>".$SMName."</span></td>";
        
        if(defined $Pos_N and $MVal ne $MVal_N)
        {
            $ChangedTypes{$TInfo->{"Name"}} = 1;
            $Content .= "<td><span class='replace'>$MVal</span> $MVal_N</td>";
        }
        else {
            $Content .= "<td>".$MVal."</td>";
        }
    }
    else
    {
        my %MTInfo = %{$ABI{$VN}->{"TypeInfo"}{$MTid}};
        my $MSize = $MTInfo{"Size"};
        my $MOffset = $MInfo{"offset"};
        
        if(defined $MInfo{"bitfield"})
        {
            $MSize = $MInfo{"bitfield"}."/".$BYTE;
            $MOffset += getBFOffset($Pos, $TID, $VN)/$BYTE;
        }
        
        my %MTInfo_N = ();
        my $MOffset_N = undef;
        my $MSize_N = undef;
        
        if(defined $Pos_N)
        {
            %MTInfo_N = %{$ABI{2}->{"TypeInfo"}{$MTid_N}};
            $MOffset_N = $MInfo_N{"offset"};
            $MSize_N = $MTInfo_N{"Size"};
            
            if(defined $MInfo{"bitfield"})
            {
                $MOffset_N += getBFOffset($Pos_N, $TID_N, 2)/$BYTE;
                $MSize_N = $MInfo_N{"bitfield"}."/".$BYTE;
            }
        }
        
        if($Added) {
            $Content .= "<td></td>";
        }
        else
        {
            if(defined $Pos_N and $Pos ne $Pos_R_N)
            {
                $ChangedTypes{$TInfo->{"Name"}} = 1;
                $Content .= "<td><span class='replace'>$Pos</span> $Pos_R_N</td>";
            }
            else {
                $Content .= "<td>$Pos</td>";
            }
        }
        
        my $SMName = $MName;
        
        if(defined $Pos_N and $MName ne $MName_N)
        {
            $ChangedTypes{$TInfo->{"Name"}} = 1;
            $SMName = "<span class='replace'>$MName</span> $MName_N";
        }
        
        if($MName eq "_vptr")
        {
            $Content .= "<td$StatusClass><span class='field'>"; # class='mem_vtable'
            if(defined $TInfo->{"VTable_Sym"}) {
                $Content .= "<a href='../symbols/".$TInfo->{"VTable_Sym"}.".html' title='view V-table'>".$MName."</a>";
            }
            else {
                $Content .= $MName;
            }
            $Content .= "</span></td>";
        }
        elsif(defined $MInfo{"bitfield"}) {
            $Content .= "<td$StatusClass><span class='field bitfield_inline'>".$SMName."</span></td>";
        }
        else {
            $Content .= "<td$StatusClass><span class='field'>".$SMName."</span></td>";
        }
        
        # type
        if(defined $Pos_N and $MTInfo{"Name"} ne $MTInfo_N{"Name"}
        and $MappedType{$MTid} ne $MTid_N)
        {
            $ChangedTypes{$TInfo->{"Name"}} = 1;
            $Content .= "<td class='field_type'><span class='replace'>".showType($MTid, $VN, "", $TID)."</span> ".showType($MTid_N, 2, "", $TID_N)."</td>";
        }
        else {
            $Content .= "<td class='field_type'>".showType($MTid, $VN, "", $TID)."</td>";
        }
        
        if(defined $Pos_N and $MSize ne $MSize_N)
        {
            $ChangedTypes{$TInfo->{"Name"}} = 1;
            $Content .= "<td><span class='replace'>$MSize</span> $MSize_N</td>";
        }
        else {
            $Content .= "<td>$MSize</td>";
        }
        
        if(defined $Pos_N and $MOffset ne $MOffset_N)
        {
            $ChangedTypes{$TInfo->{"Name"}} = 1;
            $Content .= "<td><span class='replace'>$MOffset</span> $MOffset_N</td>";
        }
        else {
            $Content .= "<td>$MOffset</td>";
        }
    }
    $Content .= "</tr>\n";
    
    return $Content;
}

sub getSymbolName($$)
{
    my ($ID, $VN) = @_;
    
    my $Name = $ABI{$VN}->{"SymbolInfo"}{$ID}{"MnglName"};
    if(not $Name) {
        $Name = $ABI{$VN}->{"SymbolInfo"}{$ID}{"ShortName"};
    }
    
    return $Name;
}

sub showCallingSequence($)
{
    my ($ID, $VN) = @_;
    my %Info = %{$ABI{$VN}->{"SymbolInfo"}{$ID}};
    my $Symbol = getSymbolName($ID, $VN);
    my $Rid = $Info{"Return"};
    
    my $Compare = compareSymbol($Symbol, $VN);
    my $ID_N = undef;
    my %Info_N = ();
    my $Rid_N = undef;
    
    if($Compare)
    {
        $ID_N = $SymbolID{2}{$Symbol};
        %Info_N = %{$ABI{2}->{"SymbolInfo"}{$ID_N}};
        $Rid_N = $Info_N{"Return"};
        
        mergeSets($ID, $ID_N, "S");
    }
    
    my $Content = "<table cellpadding='3' class='summary'>\n";
    
    $Content .= "<tr>";
    $Content .= "<th>Pos</th>";
    $Content .= "<th>Name</th>";
    $Content .= "<th>Type</th>";
    $Content .= "<th>Size</th>";
    $Content .= "<th>Passed</th>";
    $Content .= "</tr>\n";
    
    if(keys(%{$Info{"Param"}})
    or (defined $ID_N and keys(%{$Info_N{"Param"}})))
    {
        $Content .= "<tr>";
        $Content .= "<td colspan='5' align='center'>INPUT(S)</td>";
        $Content .= "</tr>";
    }
    else
    {
        $Content .= "<tr>";
        $Content .= "<td colspan='5' align='center'>INPUT(S): none</td>";
        $Content .= "</tr>";
    }
    
    my $MC = 0;
    foreach my $Pos (sort {int($a)<=>int($b)} keys(%{$Info{"Param"}}))
    {
        if(defined $ChangeStatus{"S"}{2}{$ID_N}{$Pos + $MC}{"Added"})
        {
            $ChangedSymbols{$Symbol} = 1;
            while(defined $ChangeStatus{"S"}{2}{$ID_N}{$Pos + $MC}{"Added"})
            {
                $Content .= showParam($ID_N, 2, $Pos + $MC, 0);
                $MC += 1;
            }
        }
        elsif(defined $ChangeStatus{"S"}{1}{$ID}{$Pos}{"Removed"})
        {
            $ChangedSymbols{$Symbol} = 1;
            $MC -= 1;
        }
        
        $Content .= showParam($ID, $VN, $Pos, $Compare);
    }
    
    if(defined $ID_N)
    {
        foreach my $Pos (sort {int($a)<=>int($b)} keys(%{$Info_N{"Param"}}))
        {
            if($Pos>keys(%{$Info{"Param"}}) - 1 + $MC)
            {
                if(defined $ChangeStatus{"S"}{2}{$ID_N}{$Pos}{"Added"})
                {
                    $ChangedSymbols{$Symbol} = 1;
                    $Content .= showParam($ID_N, 2, $Pos, 0);
                }
            }
        }
    }
    
    # return value
    if(($Rid and getTypeName($Rid, $VN) ne "void")
    or (defined $ID_N and $Rid_N and getTypeName($Rid_N, 2) ne "void"))
    {
        $Content .= "<tr>";
        $Content .= "<td colspan='5' align='center'>RETURN</td>";
        $Content .= "</tr>";
        
        $Content .= showReturn($ID, $VN, $Compare);
    }
    else
    {
        $Content .= "<tr>";
        $Content .= "<td colspan='5' align='center'>RETURN: none</td>";
        $Content .= "</tr>";
    }

    $Content .= "</table>\n";
    
    return $Content;
}

sub showReturn($$$)
{
    my ($ID, $VN, $Compare) = @_;
    
    my $Symbol = getSymbolName($ID, $VN);
    
    my %Info = %{$ABI{$VN}->{"SymbolInfo"}{$ID}};
    my $RTid = $Info{"Return"};
    my $RTid_P = get_PureType($RTid, $ABI{$VN});
    
    my $Content = "";
    
    my $RSet = getRSet($ID, $VN);
    my @Subj = sort {$RSet->{$a}{"Pos"}<=>$RSet->{$b}{"Pos"}} keys(%{$RSet});
    
    my $ID_N = undef;
    my $RSet_N = undef;
    my @Subj_N = ();
    
    my %Info_N = ();
    my $RTid_N = undef;
    my $RTid_P_N = undef;
    my $Removed = 0;
    
    if($Compare)
    {
        $ID_N = $SymbolID{2}{$Symbol};
        $RSet_N = getRSet($ID_N, 2);
        @Subj_N = sort {$RSet_N->{$a}{"Pos"}<=>$RSet_N->{$b}{"Pos"}} keys(%{$RSet_N});
        
        %Info_N = %{$ABI{2}->{"SymbolInfo"}{$ID_N}};
        $RTid_N = $Info_N{"Return"};
        $RTid_P_N = get_PureType($RTid_N, $ABI{2});
    }
    
    if(not defined $RSet_N)
    { # view
        foreach my $RSubj (@Subj)
        {
            $Content .= showReturnPart($ID, $VN, $RSubj, undef, $RSet, undef, "mapped");
        }
    }
    elsif($#Subj==0 and $Subj[0]!~/\w+\.\w+/)
    {
        my $RSubj = $Subj[0];
        
        if($#Subj_N==0) {
            $Content .= showReturnPart($ID, 1, $RSubj, $Subj_N[0], $RSet, $RSet_N, "mapped");
        }
        elsif($#Subj_N>0)
        { # became partial
            $Content .= showReturnPart($ID, 1, $RSubj, undef, $RSet, undef, "removed");
            $PsetStatus{1}{$ID}{$RSubj}{"Removed"} = 1;
            $ChangedSymbols{$Symbol} = 1;
            
            foreach my $RSubj_N (@Subj_N)
            {
                $Content .= showReturnPart($ID_N, 2, $RSubj_N, undef, $RSet_N, undef, "added");
                $PsetStatus{2}{$ID_N}{$RSubj_N}{"Added"} = 1;
                $ChangedSymbols{$Symbol} = 1;
            }
        }
        else
        {
            $Content .= showReturnPart($ID, 1, $RSubj, undef, $RSet, undef, "removed");
            $PsetStatus{1}{$ID}{$RSubj}{"Removed"} = 1;
            $ChangedSymbols{$Symbol} = 1;
        }
    }
    elsif($#Subj_N==0 and $Subj_N[0]!~/\w+\.\w+/)
    {
        my $RSubj_N = $Subj_N[0];
        
        if($#Subj==0) {
            $Content .= showReturnPart($ID, 1, $Subj[0], $RSubj_N, $RSet, $RSet_N, "mapped");
        }
        elsif($#Subj>0)
        { # became complete
            foreach my $RSubj (@Subj)
            {
                $Content .= showReturnPart($ID, 1, $RSubj, undef, $RSet, undef, "removed");
                $PsetStatus{1}{$ID}{$RSubj}{"Removed"} = 1;
                $ChangedSymbols{$Symbol} = 1;
            }
            $Content .= showReturnPart($ID_N, 2, $RSubj_N, undef, $RSet_N, undef, "added");
            $PsetStatus{2}{$ID_N}{$RSubj_N}{"Added"} = 1;
            $ChangedSymbols{$Symbol} = 1;
        }
        else
        {
            $Content .= showReturnPart($ID_N, 2, $RSubj_N, undef, $RSet_N, undef, "added");
            $PsetStatus{2}{$ID_N}{$RSubj_N}{"Added"} = 1;
            $ChangedSymbols{$Symbol} = 1;
        }
    }
    else
    {
        if(getTypeName($RTid_P, 1) eq getTypeName($RTid_P_N, 2)
        and $Subj[0]!~/\w+\.\w+\.\w+/)
        { # TODO: nested fields
            my $MC = 0;
            foreach my $RSubj (@Subj)
            {
                my $Mem = undef;
                my $MPos = undef;
                
                if($RSubj=~/\w+\.(\w+)/)
                {
                    $Mem = $1;
                    $MPos = getMemPos($RTid_P, $Mem, 1);
                }
                
                # added parts
                if(defined $ChangeStatus{"T"}{2}{$RTid_P_N}{$MPos+$MC}{"Added"})
                {
                    while(defined $ChangeStatus{"T"}{2}{$RTid_P_N}{$MPos+$MC}{"Added"})
                    {
                        my $RSubj_N_A = ".retval.".$ABI{2}->{"TypeInfo"}{$RTid_P_N}{"Memb"}{$MPos+$MC};
                        $Content .= showReturnPart($ID_N, 2, $RSubj_N_A, undef, $RSet_N, undef, "added");
                        $PsetStatus{2}{$ID_N}{$RSubj_N_A}{"Added"} = 1;
                        $ChangedSymbols{$Symbol} = 1;
                        $MC += 1;
                    }
                }
                
                # mapped and removed parts
                if(defined $ChangeStatus{"T"}{1}{$RTid_P}{$MPos}{"Mapped"})
                {
                    my $MPos_N = $ChangeStatus{"T"}{1}{$RTid_P}{$MPos}{"Mapped"};
                    my $RSubj_N = ".retval.".$ABI{2}->{"TypeInfo"}{$RTid_P_N}{"Memb"}{$MPos_N}{"name"};
                    $Content .= showReturnPart($ID, 1, $RSubj, $RSubj_N, $RSet, $RSet_N, "mapped");
                }
                elsif(defined $ChangeStatus{"T"}{1}{$RTid_P}{$MPos}{"Removed"})
                {
                    $MC -= 1;
                    $Content .= showReturnPart($ID, 1, $RSubj, undef, $RSet, undef, "removed");
                    $PsetStatus{1}{$ID}{$RSubj}{"Removed"} = 1;
                    $ChangedSymbols{$Symbol} = 1;
                }
            }
        }
        else
        { # TODO: merge types
            foreach my $RSubj (@Subj)
            {
                if(not defined $RSet_N->{$RSubj})
                {
                    $Content .= showReturnPart($ID, 1, $RSubj, undef, $RSet, undef, "removed");
                    $PsetStatus{1}{$ID}{$RSubj}{"Removed"} = 1;
                    $ChangedSymbols{$Symbol} = 1;
                }
                else
                {
                    $Content .= showReturnPart($ID, 1, $RSubj, $RSubj, $RSet, $RSet_N, "mapped");
                }
            }
            
            foreach my $RSubj_N (@Subj_N)
            {
                if(not defined $RSet->{$RSubj_N})
                {
                    $Content .= showReturnPart($ID_N, 2, $RSubj_N, undef, $RSet_N, undef, "added");
                    $PsetStatus{2}{$ID_N}{$RSubj_N}{"Added"} = 1;
                    $ChangedSymbols{$Symbol} = 1;
                }
            }
        }
    }
    
    return $Content;
}

sub showReturnPart($$$$$$$)
{
    my ($ID, $VN, $RSubj, $RSubj_N, $RSet, $RSet_N, $StatusClass) = @_;
    
    if($StatusClass eq "added") {
        $StatusClass = " class='added'";
    }
    elsif($StatusClass eq "removed") {
        $StatusClass = " class='removed'";
    }
    elsif($StatusClass eq "mapped") {
        $StatusClass = "";
    }
    
    my $Symbol = getSymbolName($ID, $VN);
    
    my $ID_N = undef;
    if(defined $RSet_N) {
        $ID_N = $SymbolID{2}{$Symbol};
    }
    
    my $Content = "<tr>";
    $Content .= "<td></td>";
    
    # subject
    if($Diff)
    {
        my $SRSubj = $RSubj;
        if(defined $RSet_N and $RSubj ne $RSubj_N)
        {
            $ChangedSymbols{$Symbol} = 1;
            $SRSubj = "<span class='replace'>$SRSubj</span> $RSubj_N";
        }
        $Content .= "<td$StatusClass><span class='retval'>$SRSubj</span></td>";
    }
    else {
        $Content .= "<td class='stack_return'><span class='retval'>$RSubj</span></td>";
    }
    
    # type
    my $TS = "";
    if($RSubj eq ".result_ptr") {
        $TS = "*";
    }
    my $SType = showType($RSet->{$RSubj}{"Type"}, $VN, $ID).$TS;
    if(defined $RSet_N)
    {
        my $TS_N = "";
        if($RSubj_N eq ".result_ptr") {
            $TS_N = "*";
        }
        
        my $TN1 = getTypeName($RSet->{$RSubj}{"Type"}, 1).$TS;
        my $TN2 = getTypeName($RSet_N->{$RSubj_N}{"Type"}, 2).$TS_N;
        
        if($TN1 ne $TN2)
        {
            $ChangedSymbols{$Symbol} = 1;
            $SType = "<span class='replace'>$SType</span> ".showType($RSet_N->{$RSubj_N}{"Type"}, 2, $ID_N).$TS_N;
            
            $PsetStatus{1}{$ID}{$RSubj}{"ChangedType"} = 1;
            $PsetStatus{2}{$ID_N}{$RSubj_N}{"ChangedType"} = 1;
        }
    }
    $Content .= "<td class='seq_type'>".$SType."</td>";
    
    # size
    my $SSize = $RSet->{$RSubj}{"Size"};
    if(defined $RSet_N and $SSize ne $RSet_N->{$RSubj_N}{"Size"})
    {
        $ChangedSymbols{$Symbol} = 1;
        $SSize = "<span class='replace'>$SSize</span> ".$RSet_N->{$RSubj_N}{"Size"};
    }
    $Content .= "<td>".$SSize."</td>";
    
    # passed
    my $SPassed = $RSet->{$RSubj}{"Passed"};
    if(defined $RSet_N)
    {
        my $Passed_N = $RSet_N->{$RSubj_N}{"Passed"};
        
        if($SPassed ne $Passed_N)
        {
            $ChangedSymbols{$Symbol} = 1;
            
            if(($SPassed=~/stack/ and $Passed_N!~/stack/)
            or ($SPassed!~/stack/ and $Passed_N=~/stack/))
            {
                $PsetStatus{1}{$ID}{$RSubj}{"Removed"} = 1;
                $PsetStatus{2}{$ID_N}{$RSubj_N}{"Added"} = 1;
            }
            
            $SPassed = "<span class='replace'>$SPassed</span> ".$RSet_N->{$RSubj_N}{"Passed"};
        }
    }
    $Content .= "<td>".$SPassed."</td>";
    
    $Content .= "</tr>\n";
    
    return $Content;
}

sub getRSet($$)
{
    my ($ID, $VN) = @_;
    
    my %RSet = ();
    
    my $Info = $ABI{$VN}->{"SymbolInfo"}{$ID};
    my $Rid = $Info->{"Return"};
    
    my $RConv = getCallConv_R($ID, $ABI{$VN});
    
    my $C = 0;
    foreach my $RSubj (sortConv($Rid, $RConv, $VN))
    {
        my $RPassed = $RConv->{$RSubj};
        my $Size = $ABI{$VN}->{"TypeInfo"}{$Rid}{"Size"};
        
        my $Mid = $Rid;
        
        if($RSubj eq ".result_ptr") {
            $Size = $ABI{$VN}->{"WordSize"};
        }
        elsif($RSubj=~/\.retval\.(.+)\Z/)
        {
            if($Mid = getMemType($Rid, $1, $VN)) {
                $Size = $ABI{$VN}->{"TypeInfo"}{$Mid}{"Size"};
            }
        }
        if($RPassed=~/stack/) {
            $RSet{$RSubj}{"Passed"} = $RPassed;
        }
        elsif($RPassed) {
            $RSet{$RSubj}{"Passed"} = "%".$RPassed;
        }
        
        $RSet{$RSubj}{"Type"} = $Mid;
        $RSet{$RSubj}{"Size"} = $Size;
        $RSet{$RSubj}{"Pos"} = $C++;
    }
    
    return \%RSet;
}

sub showParam($$$$)
{
    my ($ID, $VN, $Pos, $Compare) = @_;
    
    my $Symbol = getSymbolName($ID, $VN);
    
    my $Info = $ABI{$VN}->{"SymbolInfo"}{$ID};
    my $PTid = $Info->{"Param"}{$Pos}{"type"};
    my $PTid_P = get_PureType($PTid, $ABI{$VN});
    my $PName = $Info->{"Param"}{$Pos}{"name"};
    
    my $ID_N = undef;
    my $Info_N = undef;
    
    my $Pos_N = undef;
    
    my $PTid_N = undef;
    my $PTid_P_N = undef;
    my $PName_N = undef;
    
    if($Compare)
    {
        $ID_N = $SymbolID{2}{$Symbol};
        
        $Info_N = $ABI{2}->{"SymbolInfo"}{$ID_N};
        
        if(defined $ChangeStatus{"S"}{1}{$ID}{$Pos}{"Mapped"})
        {
            $Pos_N = $ChangeStatus{"S"}{1}{$ID}{$Pos}{"Mapped"};
            
            $PTid_N = $Info_N->{"Param"}{$Pos_N}{"type"};
            $PTid_P_N = get_PureType($PTid_N, $ABI{$VN});
            $PName_N = $Info_N->{"Param"}{$Pos_N}{"name"};
        }
    }
    
    my ($Added, $Removed) = (0, 0);
    if(defined $ChangeStatus{"S"}{$VN}{$ID}{$Pos}{"Added"}) {
        $Added = 1;
    }
    elsif(defined $ChangeStatus{"S"}{$VN}{$ID}{$Pos}{"Removed"}) {
        $Removed = 1;
    }
    
    my $PSet = getPSet($ID, $VN, $Pos);
    my @Subj = sort {$PSet->{$a}{"Pos"}<=>$PSet->{$b}{"Pos"}} keys(%{$PSet});
    
    my $PSet_N = undef;
    my @Subj_N = ();
    
    if($Compare and defined $Pos_N)
    {
        $PSet_N = getPSet($ID_N, 2, $Pos_N);
        @Subj_N = sort {$PSet_N->{$a}{"Pos"}<=>$PSet_N->{$b}{"Pos"}} keys(%{$PSet_N});
    }
    
    my $Content = "";
    
    my $ShowPos = $Pos;
    
    if($Added) {
        $ShowPos = undef;
    }
    
    if(not defined $PSet_N or $Added or $Removed)
    {
        foreach my $PSubj (@Subj)
        {
            my $StatusClass = "mapped";
            if($Added)
            { # mark all parts as added
                $PsetStatus{$VN}{$ID}{$PSubj}{"Added"} = 1;
                $StatusClass = "added";
            }
            elsif($Removed)
            { # mark all parts as removed
                $PsetStatus{$VN}{$ID}{$PSubj}{"Removed"} = 1;
                $StatusClass = "removed";
            }
            $Content .= showParamPart($ID, $VN, $ShowPos, $PSubj, undef, $PSet, undef, $StatusClass);
            $ShowPos = undef; # show once
        }
    }
    elsif($#Subj==0 and $Subj[0]!~/\w+\.\w+/)
    { # complete parameters
        my $PSubj = $Subj[0];
        
        if($#Subj_N==0)
        {
            $Content .= showParamPart($ID, 1, $ShowPos, $PSubj, $Subj_N[0], $PSet, $PSet_N, "mapped");
            $ShowPos = undef;
        }
        elsif($#Subj_N>0)
        { # became partial
            $Content .= showParamPart($ID, 1, $ShowPos, $PSubj, undef, $PSet, undef, "removed");
            $ShowPos = undef;
            $PsetStatus{1}{$ID}{$PSubj}{"Removed"} = 1;
            $ChangedSymbols{$Symbol} = 1;
            
            foreach my $PSubj_N (@Subj_N)
            {
                $Content .= showParamPart($ID_N, 2, $ShowPos, $PSubj_N, undef, $PSet_N, undef, "added");
                $ShowPos = undef;
                $PsetStatus{2}{$ID_N}{$PSubj_N}{"Added"} = 1;
                $ChangedSymbols{$Symbol} = 1;
            }
        }
        else
        {
            $Content .= showParamPart($ID, 1, $ShowPos, $PSubj, undef, $PSet, undef, "removed");
            $ShowPos = undef;
            $PsetStatus{1}{$ID}{$PSubj}{"Removed"} = 1;
            $ChangedSymbols{$Symbol} = 1;
        }
    }
    elsif($#Subj_N==0 and $Subj_N[0]!~/\w+\.\w+/)
    {
        my $PSubj_N = $Subj_N[0];
        
        if($#Subj==0)
        {
            $Content .= showParamPart($ID, 1, $ShowPos, $Subj[0], $PSubj_N, $PSet, $PSet_N, "mapped");
            $ShowPos = undef;
        }
        elsif($#Subj>0)
        { # became complete
            foreach my $PSubj (@Subj)
            {
                $Content .= showParamPart($ID, 1, $ShowPos, $PSubj, undef, $PSet, undef, "removed");
                $ShowPos = undef;
                $PsetStatus{1}{$ID}{$PSubj}{"Removed"} = 1;
                $ChangedSymbols{$Symbol} = 1;
            }
            $Content .= showParamPart($ID_N, 2, $ShowPos, $PSubj_N, undef, $PSet_N, undef, "added");
            $ShowPos = undef;
            $PsetStatus{2}{$ID_N}{$PSubj_N}{"Added"} = 1;
            $ChangedSymbols{$Symbol} = 1;
        }
        else
        {
            $Content .= showParamPart($ID_N, 2, $ShowPos, $PSubj_N, undef, $PSet_N, undef, "added");
            $ShowPos = undef;
            $PsetStatus{2}{$ID_N}{$PSubj_N}{"Added"} = 1;
            $ChangedSymbols{$Symbol} = 1;
        }
    }
    else
    {
        if(getTypeName($PTid_P, 1) eq getTypeName($PTid_P_N, 2)
        and $Subj[0]!~/\w+\.\w+\.\w+/)
        {
            my $MC = 0;
            foreach my $PSubj (@Subj)
            {
                my $Mem = undef;
                my $MPos = undef;
                
                if($PSubj=~/\w+\.(\w+)/)
                {
                    $Mem = $1;
                    $MPos = getMemPos($PTid_P, $Mem, 1);
                }
                
                # added parts
                if(defined $ChangeStatus{"T"}{2}{$PTid_P_N}{$MPos+$MC}{"Added"})
                {
                    while(defined $ChangeStatus{"T"}{2}{$PTid_P_N}{$MPos+$MC}{"Added"})
                    {
                        my $PSubj_N_A = $PName_N.".".$ABI{2}->{"TypeInfo"}{$PTid_P_N}{"Memb"}{$MPos+$MC};
                        $Content .= showParamPart($ID_N, 2, $ShowPos, $PSubj_N_A, undef, $PSet_N, undef, "added");
                        $PsetStatus{2}{$ID_N}{$PSubj_N_A}{"Added"} = 1;
                        $ChangedSymbols{$Symbol} = 1;
                        $ShowPos = undef;
                        $MC += 1;
                    }
                }
                
                # mapped and removed parts
                my $PSubj_N = undef;
                if(defined $ChangeStatus{"T"}{1}{$PTid_P}{$MPos}{"Mapped"})
                { # same type
                    my $MPos_N = $ChangeStatus{"T"}{1}{$PTid_P}{$MPos}{"Mapped"};
                    $PSubj_N = $PName_N.".".$ABI{2}->{"TypeInfo"}{$PTid_P_N}{"Memb"}{$MPos_N}{"name"};
                    $Content .= showParamPart($ID, 1, $ShowPos, $PSubj, $PSubj_N, $PSet, $PSet_N, "mapped");
                    $ShowPos = undef;
                }
                elsif(defined $ChangeStatus{"T"}{1}{$PTid_P}{$MPos}{"Removed"})
                {
                    $Content .= showParamPart($ID, 1, $ShowPos, $PSubj, undef, $PSet, undef, "removed");
                    $PsetStatus{1}{$ID}{$PSubj}{"Removed"} = 1;
                    $ChangedSymbols{$Symbol} = 1;
                    $ShowPos = undef;
                    $MC -= 1;
                }
            }
        }
        else
        { # TODO: merge types
            foreach my $PSubj (@Subj)
            {
                my $PSubj_N = $PSubj;
                $PSubj_N=~s/\A\Q$PName\E(\.)/$PName_N$1/;
                
                if(not defined $PSet_N->{$PSubj_N})
                {
                    $Content .= showParamPart($ID, 1, $ShowPos, $PSubj, undef, $PSet, undef, "removed");
                    $PsetStatus{1}{$ID}{$PSubj}{"Removed"} = 1;
                    $ChangedSymbols{$Symbol} = 1;
                }
                else {
                    $Content .= showParamPart($ID, 1, $ShowPos, $PSubj, $PSubj_N, $PSet, $PSet_N, "mapped");
                }
                $ShowPos = undef;
            }
            
            foreach my $PSubj_N (@Subj_N)
            {
                my $PSubj = $PSubj_N;
                $PSubj=~s/\A\Q$PName_N\E(\.)/$PName$1/;
                
                if(not defined $PSet->{$PSubj})
                {
                    $Content .= showParamPart($ID_N, 2, $ShowPos, $PSubj_N, undef, $PSet_N, undef, "added");
                    $PsetStatus{2}{$ID_N}{$PSubj_N}{"Added"} = 1;
                    $ChangedSymbols{$Symbol} = 1;
                    $ShowPos = undef;
                }
            }
        }
    }
    
    return $Content;
}

sub showParamPart($$$$$$$$)
{
    my ($ID, $VN, $Pos, $PSubj, $PSubj_N, $PSet, $PSet_N, $StatusClass) = @_;
    
    if($StatusClass eq "added") {
        $StatusClass = " class='added'";
    }
    elsif($StatusClass eq "removed") {
        $StatusClass = " class='removed'";
    }
    elsif($StatusClass eq "mapped") {
        $StatusClass = "";
    }
    
    my $Symbol = getSymbolName($ID, $VN);
    
    my $ID_N = undef;
    my $Pos_N = undef;
    my $Pos_R_N = undef;
    
    my $Content = "<tr>";
    
    # position
    if(defined $Pos)
    {
        my $SPos = $Pos;
        if(defined $PSet_N)
        {
            $ID_N = $SymbolID{2}{$Symbol};
            $Pos_N = $ChangeStatus{"S"}{1}{$ID}{$Pos}{"Mapped"};
            $Pos_R_N = $ChangeStatus{"S"}{2}{$ID_N}{$Pos_N}{"Mapped_Rel"};
            
            if($Pos ne $Pos_R_N)
            {
                $ChangedSymbols{$Symbol} = 1;
                $SPos = "<span class='replace'>$Pos</span> $Pos_R_N";
            }
        }
        
        $Content .= "<td>$SPos</td>";
    }
    else {
        $Content .= "<td></td>";
    }
    
    # subject
    my $SPSubj = $PSubj;
    if(defined $PSet_N and $PSubj ne $PSubj_N)
    {
        $ChangedSymbols{$Symbol} = 1;
        $SPSubj = "<span class='replace'>$PSubj</span> $PSubj_N";
    }
    $Content .= "<td$StatusClass><span class='param'>$SPSubj</span></td>";
    
    # type
    my $SType = showType($PSet->{$PSubj}{"Type"}, $VN, $ID);
    if(defined $PSet_N)
    {
        my $TN1 = getTypeName($PSet->{$PSubj}{"Type"}, $VN);
        my $TN2 = getTypeName($PSet_N->{$PSubj_N}{"Type"}, 2);
        
        if($TN1 ne $TN2)
        {
            $ChangedSymbols{$Symbol} = 1;
            $SType = "<span class='replace'>$SType</span> ".showType($PSet_N->{$PSubj_N}{"Type"}, 2, $ID_N);
            
            $PsetStatus{1}{$ID}{$PSubj}{"ChangedType"} = 1;
            $PsetStatus{2}{$ID_N}{$PSubj_N}{"ChangedType"} = 1;
        }
    }
    $Content .= "<td class='seq_type'>".$SType."</td>";
    
    # size
    my $SSize = $PSet->{$PSubj}{"Size"};
    if(defined $PSet_N and $SSize ne $PSet_N->{$PSubj_N}{"Size"})
    {
        $ChangedSymbols{$Symbol} = 1;
        $SSize = "<span class='replace'>$SSize</span> ".$PSet_N->{$PSubj_N}{"Size"};
    }
    $Content .= "<td>".$SSize."</td>";
    
    # passed
    my $SPassed = $PSet->{$PSubj}{"Passed"};
    if(defined $PSet_N)
    {
        my $Passed_N = $PSet_N->{$PSubj_N}{"Passed"};
        
        if($SPassed ne $Passed_N)
        {
            $ChangedSymbols{$Symbol} = 1;
            if(($SPassed=~/stack/ and $Passed_N!~/stack/)
            or ($SPassed!~/stack/ and $Passed_N=~/stack/))
            {
                $PsetStatus{1}{$ID}{$PSubj}{"Removed"} = 1;
                $PsetStatus{2}{$ID_N}{$PSubj_N}{"Added"} = 1;
            }
            
            $SPassed = "<span class='replace'>$SPassed</span> ".$Passed_N;
        }
    }
    $Content .= "<td>".$SPassed."</td>";
    
    $Content .= "</tr>\n";
    
    return $Content;
}

sub getPSet($$$)
{
    my ($ID, $VN, $Pos) = @_;
    
    my %PSet = ();
    
    my $Info = $ABI{$VN}->{"SymbolInfo"}{$ID};
    my $Tid = $Info->{"Param"}{$Pos}{"type"};
    
    if(getTypeName($Tid, $VN) eq "...")
    {
        my $PSubj = "...";
        
        $PSet{$PSubj}{"Type"} = "-1";
        $PSet{$PSubj}{"Size"} = "...";
        $PSet{$PSubj}{"Passed"} = "stack + n";
        $PSet{$PSubj}{"Pos"} = 0;
        
        return \%PSet;
    }
    
    my $PConv = getCallConv_P($ID, $ABI{$VN}, $Pos);
    
    if(not $PConv) {
        return undef;
    }
    
    my $C = 0;
    foreach my $PSubj (sortConv($Tid, $PConv, $VN))
    {
        my $PPassed = $PConv->{$PSubj};
        
        if(not $PPassed) {
            print STDERR "WARNING: missed calling convention for $PSubj in ".getSymbolName($ID, $VN)."\n";
        }
        
        my $Size = $ABI{$VN}->{"TypeInfo"}{$Tid}{"Size"};
        my $Mid = $Tid;
        
        if($PSubj=~/\A\w+\.(.+)\Z/)
        {
            if($Mid = getMemType($Tid, $1, $VN)) {
                $Size = $ABI{$VN}->{"TypeInfo"}{$Mid}{"Size"};
            }
        }
        
        $PSet{$PSubj}{"Type"} = $Mid;
        $PSet{$PSubj}{"Size"} = $Size;
        
        if($PPassed=~/stack/) {
            $PSet{$PSubj}{"Passed"} = $PPassed;
        }
        elsif($PPassed) {
            $PSet{$PSubj}{"Passed"} = "%".$PPassed;
        }
        else {
            $PSet{$PSubj}{"Passed"} = "";
        }
        
        $PSet{$PSubj}{"Pos"} = $C++;
    }
    
    return \%PSet;
}

sub showBaseClasses($$)
{
    my ($TID, $VN) = @_;
    my %TInfo = %{$ABI{$VN}->{"TypeInfo"}{$TID}};
    
    my $Content = "";
    
    if(defined $TInfo{"Base"})
    {
        my @Base = keys(%{$TInfo{"Base"}});
        @Base = sort {int($TInfo{"Base"}{$a}{"pos"})<=>int($TInfo{"Base"}{$b}{"pos"})} @Base;
        
        foreach my $Bid (@Base)
        {
            my $Pos = $TInfo{"Base"}{$Bid}{"pos"};
            
            if($#Base>0) {
                $Content .= $Pos.": ";
            }
            
            $Content .= showType($Bid, $VN, "", $TID);
            $Content .= "<br/>";
        }
    }
    
    return $Content;
}

sub getBFOffset($$$)
{
    my ($Pos, $TID, $VN) = @_;
    my %TInfo = %{$ABI{$VN}->{"TypeInfo"}{$TID}};
    
    my $BFOffset = 0; # in bits
    
    if(defined $TInfo{"Memb"}{$Pos}{"bitfield"})
    {
        my $Offset = $TInfo{"Memb"}{$Pos}{"offset"};
        
        foreach my $P (sort {int($a)<=>int($b)} keys(%{$TInfo{"Memb"}}))
        {
            if($TInfo{"Memb"}{$P}{"offset"} eq $Offset and $P<$Pos
            and defined $TInfo{"Memb"}{$P}{"bitfield"})
            {
                $BFOffset += $TInfo{"Memb"}{$P}{"bitfield"};
            }
        }
    }
    
    return $BFOffset;
}

sub showHeight(@)
{
    my $Size = shift(@_);
    
    my $Type = "S";
    my $Del = 1;
    
    if(@_) {
        $Type = shift(@_);
    }
    
    if(@_) {
        $Del = shift(@_);
    }
    
    if($Type eq "U")
    {
        return "style='height:".(25*$Size/$Del)."px'";
    }
    else
    {
        if(not $Diff)
        {
            if($Size>=40) {
                $Size = 40;
            }
        }
        
        return "style='height:".(20*$Size/$Del)."px'";
    }
}

sub shortName($$)
{
    my ($N, $S) = @_;
    
    if($S==1)
    {
        if(length($N)>15)
        {
            $N = substr($N, 0, 12)."...";
        }
    }
    
    return $N;
}

sub showName($$)
{
    my ($N, $S) = @_;
    
    if(length($N)>15 and $S==1) {
        return "_inline";
    }
    
    return "";
}

sub countUsage($$)
{
    my ($TID, $VN) = @_;
    
    my @FP = sort keys(%{$FuncParam{$VN}{$TID}});
    my @FR = sort keys(%{$FuncReturn{$VN}{$TID}});
    my @TM = sort keys(%{$TypeMemb{$VN}{$TID}});
    my @FptrP = sort keys(%{$FPtrParam{$VN}{$TID}});
    
    my $Total = 0;
    
    foreach my $ID (@FP)
    {
        foreach my $PName (sort keys(%{$FuncParam{$VN}{$TID}{$ID}}))
        {
            $Total += 1;
        }
    }
    
    $Total += $#FR+1;
    
    foreach my $ID (@TM)
    {
        foreach my $MName (sort keys(%{$TypeMemb{$VN}{$TID}{$ID}}))
        {
            $Total += 1;
        }
    }
    
    foreach my $ID (@FptrP)
    {
        foreach my $Pos (sort keys(%{$FPtrParam{$VN}{$TID}{$ID}}))
        {
            $Total += 1;
        }
    }
    
    return $Total;
}

sub showUsage($$)
{
    my ($TID, $VN) = @_;
    
    my @FP = sort keys(%{$FuncParam{$VN}{$TID}});
    my @FR = sort keys(%{$FuncReturn{$VN}{$TID}});
    my @TM = sort keys(%{$TypeMemb{$VN}{$TID}});
    my @FptrP = sort keys(%{$FPtrParam{$VN}{$TID}});
    
    if(not @FP and not @FR and not @TM and not @FptrP) {
        return undef;
    }
    
    my %TInfo = %{$ABI{$VN}->{"TypeInfo"}{$TID}};
    
    my $Total = 0;
    my %UsedTypes = ();
    my %UsedFuncs = ();
    
    my $Content = "";
    
    foreach my $ID (@FP)
    {
        foreach my $PName (sort keys(%{$FuncParam{$VN}{$TID}{$ID}}))
        {
            $Content .= "<tr>\n";
            
            $Content .= "<td align='center' class='func'>\n";
            $Content .= "PARAM";
            $Content .= "</td>\n";
            
            $Content .= "<td align='center' class='short'>\n";
            $Content .= "<span class='param'>".$PName."</span>";
            $Content .= "</td>\n";
            
            $Content .= "<td valign='top' class='short'>\n";
            $Content .= get_Signature($ABI{$VN}->{"SymbolInfo"}{$ID}, $VN, 1, 1, $PName)." <a class='info' href='../symbols/".getSymbolName($ID, $VN).".html'>&raquo;</a>\n";
            # $Content .= $ABI{$VN}->{"SymbolInfo"}{$ID}{"ShortName"}." <a class='info' href='../symbols/".getSymbolName($ID, $VN).".html'>&raquo;</a>\n";
            $Content .= "</td>\n";
            
            $Content .= "</tr>\n";
            
            $Total += 1;
        }
        
        $UsedFuncs{$ID} = 1;
    }
    
    foreach my $ID (@FR)
    {
        $Content .= "<tr>\n";
        
        $Content .= "<td align='center' class='return'>\n";
        $Content .= "RETURN";
        $Content .= "</td>\n";
        
        $Content .= "<td align='center' class='short'>\n";
        $Content .= "</td>\n";
        
        $Content .= "<td valign='top' class='short'>";
        $Content .= get_Signature($ABI{$VN}->{"SymbolInfo"}{$ID}, $VN, 1, 1)." <a class='info' href='../symbols/".getSymbolName($ID, $VN).".html'>&raquo;</a>\n";
        $Content .= "</td>\n";
        
        $Content .= "</tr>\n";
        
        $Total += 1;
        
        $UsedFuncs{$ID} = 1;
    }
    
    foreach my $ID (@TM)
    {
        foreach my $MName (sort keys(%{$TypeMemb{$VN}{$TID}{$ID}}))
        {
            $Content .= "<tr>\n";
            
            $Content .= "<td align='center' class='stack_param'>\n";
            $Content .= "FIELD";
            $Content .= "</td>\n";
            
            $Content .= "<td align='center' class='short'>\n";
            $Content .= "<span class='field'>.".$MName."</span>";
            $Content .= "</td>\n";
            
            $Content .= "<td valign='top' class='short'>";
            $Content .= get_Signature_T($ABI{$VN}->{"TypeInfo"}{$ID}, $VN, $MName)." <a class='info' href='../types/".getUname_T($ID, $VN).".html'>&raquo;</a>\n";
            # $Content .= $ABI{$VN}->{"TypeInfo"}{$ID}{"Name"}." <a class='info' href='../types/".getUname_T($ID, $VN).".html'>&raquo;</a>\n";
            $Content .= "</td>\n";
            
            $Content .= "</tr>\n";
            
            $Total += 1;
        }
        
        $UsedTypes{$ID} = 1;
    }
    
    foreach my $ID (@FptrP)
    {
        foreach my $Pos (sort keys(%{$FPtrParam{$VN}{$TID}{$ID}}))
        {
            $Content .= "<tr>\n";
            
            $Content .= "<td align='center' class='fptr'>\n";
            if($Pos eq "ret") {
                $Content .= "F-PTR<br/>RETURN";
            }
            elsif($Pos eq "type") {
                $Content .= "FIELD-PTR<br/>TYPE";
            }
            else {
                $Content .= "F-PTR<br/>PARAM";
            }
            $Content .= "</td>\n";
            
            $Content .= "<td align='center' class='short'>\n";
            if($Pos ne "ret") {
                $Content .= showPos($Pos+1)." parameter";
            }
            $Content .= "</td>\n";
            
            $Content .= "<td valign='top' class='short'>";
            $Content .= get_Signature_FP($ABI{$VN}->{"TypeInfo"}{$ID}, $VN, $Pos)." <a class='info' href='../types/".getUname_T($ID, $VN).".html'>&raquo;</a>\n";
            $Content .= "</td>\n";
            
            $Content .= "</tr>\n";
            
            $Total += 1;
        }
        
        $UsedTypes{$ID} = 1;
    }
    
    my $Sort = "class='sort' onclick='sort(this)'";
    
    my $Head = "";
    
    $Head .= "<table id='List' cellpadding='3' class='summary'>\n";
    $Head .= "<tr>\n";
    $Head .= "<th $Sort title='sort'>Used As</th>\n";
    $Head .= "<th $Sort title='sort'>Name</th>\n";
    $Head .= "<th $Sort title='sort'>Used In</th>\n";
    $Head .= "</tr>\n";
    
    $Content = $Head.$Content;
    $Content .= "</table>\n";
    
    my $Head = showMenu("type");
    $Head .= "<h1 style='max-width:1024px; word-wrap:break-word;'>Type Usage:&nbsp;<a class='black' href='../types/".getUname_T($TID, $VN).".html'>".htmlSpecChars(rmQual($TInfo{"Name"}))."</a> ($Total)</h1>\n";
    $Head .= "<br/>\n";
    
    $Content = $Head.$Content;
    
    my $HtmlName = htmlSpecChars($TInfo{"Name"}, 1);
    
    # document
    $Content = composeHTML_Head("Usage: ".$HtmlName, "$HtmlName, used, field, parameter, types, symbols", "Usage of type in the library", getTop("type"), "report.css", "sort.js")."<body>\n".$Content;
    
    if($SHOW_DEV) {
        $Content .= getSign();
    }
    
    $Content .= "</body>\n";
    $Content .= "</html>\n";
    
    my $Url = "usage/".getUname_T($TID, $VN).".html";
    
    writeFile($Output."/".$Url, $Content);
    
    my $Summary = "";
    my @Sen = ();
    
    if(my $F = keys(%UsedFuncs)) {
        push(@Sen, "<a href='../".$Url."'>$F</a> symbol".getS($F));
    }
    
    if(my $T = keys(%UsedTypes)) {
        push(@Sen, "<a href='../".$Url."'>$T</a> type".getS($T));
    }
    
    $Summary .= "The type is used by ".join(" and ", @Sen).".";
    
    return $Summary;
}

sub showPos($)
{
    my $N = $_[0];
    
    my %Suffix = (
        1=>"st",
        2=>"nd",
        3=>"rd",
    );
    
    if(my $S = $Suffix{$N})
    {
        return $N.$S;
    }
    
    return $N."th";
}

sub getS($)
{
    if($_[0]>1) {
        return "s";
    }
    
    return "";
}

sub showMemoryLayout($$)
{
    my ($TID, $VN) = @_;
    my %TInfo = %{$ABI{$VN}->{"TypeInfo"}{$TID}};
    
    my %OffsetMem = ();
    
    if(defined $TInfo{"Memb"})
    {
        foreach my $Pos (sort {int($a)<=>int($b)} keys(%{$TInfo{"Memb"}}))
        {
            my %MInfo = %{$TInfo{"Memb"}{$Pos}};
            
            if(defined $MInfo{"offset"})
            {
                my $Offset = $MInfo{"offset"} + getBFOffset($Pos, $TID, $VN)/$BYTE;
                $OffsetMem{$Offset} = $Pos;
            }
        }
    }
    
    my $Content = "";
    
    $Content .= "<table cellpadding='3' class='stack_frame'>\n";
    
    $Content .= "<tr>";
    $Content .= "<th>Offset</th>";
    $Content .= "<th>Contents</th>";
    $Content .= "<th>Type</th>";
    $Content .= "</tr>\n";
    
    my @Order = sort {int($a*$BYTE)<=>int($b*$BYTE)} keys(%OffsetMem);
    
    # base type
    if(defined $TInfo{"Base"})
    {
        my $BSize = 0;
        if(@Order)
        {
            if($Order[0]!=0) {
                $BSize = $Order[0];
            }
        }
        else {
            $BSize = $TInfo{"Size"};
        }
        
        if($BSize)
        {
            $Content .= "<tr>";
            $Content .= "<td class='stack_offset'>0</td>";
            $Content .= "<td class='stack_value stack_data'>base<br/>class</td>";
            $Content .= "<td class='stack_value' ".showHeight($BSize, "S").">".showBaseClasses($TID, $VN)."</td>";
            $Content .= "</tr>\n";
        }
    }
    
    foreach my $N (0 .. $#Order)
    {
        my $Offset = $Order[$N];
        
        my $Pos = $OffsetMem{$Offset};
        my %MInfo = %{$TInfo{"Memb"}{$Pos}};
        my $MTid = $MInfo{"type"};
        my $MName = $MInfo{"name"};
        my $Size = $ABI{$VN}->{"TypeInfo"}{$MTid}{"Size"};
        my $MSize = $Size;
        
        if(defined $MInfo{"bitfield"}) {
            $MSize = $MInfo{"bitfield"}/$BYTE;
        }
        
        # field
        $Content .= "<tr>\n";
        $Content .= "<td class='stack_offset'>$Offset</td>";
        if($MName eq "_vptr")
        {
            my $C = "stack_vtable";
            
            if(defined $Diff)
            {
                if(defined $ChangeStatus{"T"}{$VN}{$TID}{$Pos}{"Added"}) {
                    $C = "added";
                }
                elsif(defined $ChangeStatus{"T"}{$VN}{$TID}{$Pos}{"Removed"}) {
                    $C = "removed";
                }
            }
            
            $Content .= "<td class=\'stack_value $C\'><span class='param'>";
            if(defined $TInfo{"VTable_Sym"}) {
                $Content .= "<a href='../symbols/".$TInfo{"VTable_Sym"}.".html' title='view V-table'>.".$MName."</a>";
            }
            else {
                $Content .= ".".$MName;
            }
            $Content .= "</span></td>";
        }
        elsif(defined $MInfo{"bitfield"})
        {
            my $C = "bitfield";
            if(defined $Diff)
            {
                if(defined $ChangeStatus{"T"}{$VN}{$TID}{$Pos}{"Added"}) {
                    $C = "added";
                }
                elsif(defined $ChangeStatus{"T"}{$VN}{$TID}{$Pos}{"Removed"}) {
                    $C = "removed";
                }
            }
            $Content .= "<td class='stack_value $C".showName($MName, $MSize)."'><span class='param'>.$MName</span></td>";
        }
        else
        {
            my $C = "stack_param";
            if(defined $Diff)
            {
                if(defined $ChangeStatus{"T"}{$VN}{$TID}{$Pos}{"Added"}) {
                    $C = "added";
                }
                elsif(defined $ChangeStatus{"T"}{$VN}{$TID}{$Pos}{"Removed"}) {
                    $C = "removed";
                }
            }
            $Content .= "<td class='stack_value $C".showName($MName, $MSize)."'><span class='param'>.$MName</span></td>";
        }
        
        my $ShowType = showType($MTid, $VN, "", $TID);
        #my $Cl = "";
        if(defined $Diff)
        {
            if($VN==1 and my $TID_N = $MappedType{$TID})
            {
                if(defined $ChangeStatus{"T"}{1}{$TID}{$Pos}{"Mapped"})
                {
                    my $Pos_N = $ChangeStatus{"T"}{1}{$TID}{$Pos}{"Mapped"};
                    my $MTid_N = $ABI{2}->{"TypeInfo"}{$TID_N}{"Memb"}{$Pos_N}{"type"};
                    
                    if(getTypeName($MTid_N, 2) ne getTypeName($MTid, 1)
                    and $MappedType{$MTid} ne $MTid_N)
                    {
                        # $Cl = " replace_l";
                        $ShowType = "<span class='replace_l'>".$ShowType."</span>";
                    }
                }
            }
            elsif($VN==2 and my $TID_P = $MappedType_R{$TID})
            {
                if(defined $ChangeStatus{"T"}{2}{$TID}{$Pos}{"Mapped"})
                {
                    my $Pos_P = $ChangeStatus{"T"}{2}{$TID}{$Pos}{"Mapped"};
                    my $MTid_P = $ABI{1}->{"TypeInfo"}{$TID_P}{"Memb"}{$Pos_P}{"type"};
                    my $MTName_P = getTypeName($MTid_P, 1);
                    
                    if($MTName_P ne getTypeName($MTid, 2))
                    {
                        if($MappedType_R{$MTid} ne $MTid_P)
                        {
                            # $Cl = " added";
                            $ShowType = "<span class='added_l'>".$ShowType."</span>";
                        }
                        elsif(index($MTName_P, "anon-")==0)
                        {
                            $ShowType = showType($MTid_P, 1, "", $TID_P);
                        }
                    }
                }
            }
        }
        
        $Content .= "<td class='stack_value\' ".showHeight($MSize).">".$ShowType."</td>";
        $Content .= "</tr>\n";
        
        # padding
        my $Offset_N = undef;
        if($N<$#Order) {
            $Offset_N = $Order[$N + 1];
        }
        elsif($N==$#Order)
        { # tail padding
            $Offset_N = $TInfo{"Size"};
        }
        
        if($Offset_N)
        {
            if(my $Delta = abs($Offset_N-$Offset)-$MSize)
            {
                my $POffset = $Offset + $MSize;
                
                $Content .= "<tr>\n";
                $Content .= "<td class='stack_offset'>$POffset</td>";
                $Content .= "<td class='stack_value padding'>padding</td>"; # $Delta bytes<br/>
                $Content .= "<td class='stack_value' ".showHeight($Delta)."></td>";
                $Content .= "</tr>\n";
            }
        }
    }
    
    $Content .= "</table>\n";
    
    return $Content;
}

sub showUnionLayout($$)
{
    my ($TID, $VN) = @_;
    my %TInfo = %{$ABI{$VN}->{"TypeInfo"}{$TID}};
    
    my $Content = "<table cellspacing='0' cellpadding='0'>";
    $Content .= "<tr>";
    
    my $Del = 1;
    if($TInfo{"Size"}>256) {
        $Del = 5*$TInfo{"Size"}/256;
    }
    
    if(defined $TInfo{"Memb"})
    {
        foreach my $Pos (sort {int($a)<=>int($b)} keys(%{$TInfo{"Memb"}}))
        {
            my %MInfo = %{$TInfo{"Memb"}{$Pos}};
            my $Mid = $MInfo{"type"};
            my $MName = $MInfo{"name"};
            my $Size = $ABI{$VN}->{"TypeInfo"}{$Mid}{"Size"};
            my $MSize = $Size;
            
            if(defined $MInfo{"bitfield"}) {
                $MSize = $MInfo{"bitfield"}/$BYTE;
            }
            
            my $ZeroOffset = 0;
            my $ShowMName = ".".$MName;
            my $MCl = "stack_param";
            my $MType = showType($Mid, $VN, "", $TID);
            
            if(defined $MInfo{"bitfield"})
            {
                if($MInfo{"bitfield"}<8)
                {
                    $ZeroOffset = "";
                    $ShowMName = "";
                    $MType = "";
                }
                $MCl = "bitfield_inline";
            }
            
            my $Padding = $TInfo{"Size"} - $MSize;
            
            $Content .= "<td style='padding-right:30px;'>";
            
            $Content .= "<span class='num'>$Pos) .$MName</span>";
            $Content .= "<br/>";
            $Content .= "<br/>";
            $Content .= "<table cellpadding='0' cellspacing='0' class='union_layout'>\n";
            
            $Content .= "<tr>";
            $Content .= "<th>Offset</th>";
            $Content .= "<th>Contents</th>";
            $Content .= "<th>Type</th>";
            $Content .= "</tr>\n";

            $Content .= "<tr>";
            $Content .= "<td class='stack_offset'>$ZeroOffset</td>";
            $Content .= "<td class='union_value $MCl\' ".showHeight($MSize, "U", $Del)."><span class='param'>$ShowMName</span></td>";
            $Content .= "<td class='union_value'>$MType</td>";
            $Content .= "</tr>\n";
            
            if($Padding)
            {
                $Content .= "<tr>";
                $Content .= "<td class='stack_offset'>$MSize</td>";
                $Content .= "<td class='union_value padding' ".showHeight($Padding, "U", $Del).">padding</td>";
                $Content .= "<td class='union_value'></td>";
                $Content .= "</tr>\n";
            }
            
            $Content .= "</table>";
            
            $Content .= "</td>";
            
            if($Pos!=0 and ($Pos+1) % 4==0)
            {
                $Content .= "</tr><tr><td style='height:30px;'></td>";
                $Content .= "</tr><tr>";
            }
        }
    }
    
    $Content .= "</tr>";
    $Content .= "</table>";
    
    return $Content;
}

sub showStackFrame($$)
{
    my ($ID, $VN) = @_;
    my %Info = %{$ABI{$VN}->{"SymbolInfo"}{$ID}};
    
    my %OffsetParam = ();
    
    if(defined $Info{"Param"})
    {
        foreach my $Pos (sort {int($a)<=>int($b)} keys(%{$Info{"Param"}}))
        {
            my %PInfo = %{$Info{"Param"}{$Pos}};
            
            if(defined $PInfo{"offset"})
            {
                $OffsetParam{$PInfo{"offset"}} = $Pos;
            }
        }
    }
    
    my $Content = "";
    
    $Content .= "<table cellpadding='3' class='stack_frame'>\n";
    
    $Content .= "<tr>";
    $Content .= "<th>Offset</th>";
    $Content .= "<th>Contents</th>";
    $Content .= "<th>Type</th>";
    $Content .= "</tr>\n";
    
    # data, saved registers
    $Content .= "<tr>";
    $Content .= "<td class='stack_offset'></td>";
    $Content .= "<td class='stack_value stack_data'>local space,<br/>return address,<br/>etc.</td>";
    $Content .= "<td class='stack_value'></td>";
    $Content .= "</tr>\n";
    
    if(my $Rid = $Info{"Return"})
    {
        my $RConv = getCallConv_R($ID, $ABI{$VN});
        
        foreach my $RSubj (sortConv($Rid, $RConv, $VN))
        {
            my $RPassed = $RConv->{$RSubj};
            
            if($RPassed and $RPassed=~/stack ([+-])\s*(\d+)/)
            {
                my $Offset = $2;
                my $Dir = $1;
                
                if($Dir eq "-") {
                    $Offset = $Dir.$Offset;
                }
                
                my $Size = $ABI{$VN}->{"TypeInfo"}{$Rid}{"Size"};
                my $TS = "";
                my $Mid = $Rid;
                
                if($RSubj eq ".result_ptr")
                {
                    $Size = $ABI{$VN}->{"WordSize"};
                    $TS = "*";
                }
                elsif($RSubj=~/\.retval\.(.+)\Z/)
                {
                    if($Mid = getMemType($Rid, $1, $VN)) {
                        $Size = $ABI{$VN}->{"TypeInfo"}{$Mid}{"Size"};
                    }
                }
                
                my $C = "stack_return";
                if(defined $PsetStatus{$VN}{$ID}{$RSubj}{"Added"}) {
                    $C = "added";
                }
                elsif(defined $PsetStatus{$VN}{$ID}{$RSubj}{"Removed"}) {
                    $C = "removed";
                }
                
                $Content .= "<tr>\n";
                $Content .= "<td class='stack_offset'>$Offset</td>";
                $Content .= "<td class=\'stack_value $C\'><span class='param'>$RSubj</span></td>";
                
                my $SType = showType($Mid, $VN, $ID).$TS;
                if(defined $PsetStatus{$VN}{$ID}{$RSubj}{"ChangedType"})
                {
                    if($VN==1) {
                        $SType = "<span class='replace_l'>".$SType."</span>";
                    }
                    else {
                        $SType = "<span class='added_l'>".$SType."</span>";
                    }
                }
                $Content .= "<td class='stack_value' ".showHeight($Size).">".$SType."</td>";
                $Content .= "</tr>\n";
            }
        }
    }
    
    my @Order = sort {int($a)<=>int($b)} keys(%OffsetParam);
    
    if(@Order and $Order[0]<0) {
        @Order = reverse(@Order);
    }
    
    foreach my $N (0 .. $#Order)
    {
        my $Offset = $Order[$N];
        
        my $Pos = $OffsetParam{$Offset};
        my %PInfo = %{$Info{"Param"}{$Pos}};
        my $Tid = $PInfo{"type"};
        my $Size = $ABI{$VN}->{"TypeInfo"}{$Tid}{"Size"};
        my $PSubj = $PInfo{"name"};
        
        my $C = "stack_param";
        if(defined $PsetStatus{$VN}{$ID}{$PSubj}{"Added"}) {
            $C = "added";
        }
        elsif(defined $PsetStatus{$VN}{$ID}{$PSubj}{"Removed"}) {
            $C = "removed";
        }
        
        $Content .= "<tr>\n";
        $Content .= "<td class='stack_offset'>$Offset</td>";
        $Content .= "<td class='stack_value $C".showName($PSubj, $Size)."'><span class='param'>".$PSubj."</span></td>";
        
        my $SType = showType($Tid, $VN, $ID);
        if(defined $PsetStatus{$VN}{$ID}{$PSubj}{"ChangedType"})
        {
            if($VN==1) {
                $SType = "<span class='replace_l'>".$SType."</span>";
            }
            else {
                $SType = "<span class='added_l'>".$SType."</span>";
            }
        }
        $Content .= "<td class='stack_value' ".showHeight($Size).">".$SType."</td>";
        $Content .= "</tr>\n";
        
        my $Offset_N = undef;
        if($N<$#Order) {
            $Offset_N = $Order[$N + 1];
        }
        
        if($Offset_N and my $Delta = abs($Offset_N-$Offset)-$Size)
        {
            my $POffset = $Offset + $Size;
            if($Order[0]<0) {
                $POffset = $Offset - $Size;
            }
            
            $Content .= "<tr>\n";
            $Content .= "<td class='stack_offset'>$POffset</td>";
            $Content .= "<td class='stack_value padding'>padding</td>"; # $Delta bytes<br/>
            $Content .= "<td class='stack_value' ".showHeight($Delta)."></td>";
            $Content .= "</tr>\n";
        }
    }
    
    if(defined $Info{"Param"})
    {
        my @Params = sort {int($a)<=>int($b)} keys(%{$Info{"Param"}});
        
        my $Last = $Params[$#Params];
        my $PType = $Info{"Param"}{$Last}{"type"};
        
        if($PType eq "-1")
        {
            $Content .= "<tr>\n";
            $Content .= "<td class='stack_offset'>n</td>";
            $Content .= "<td class='stack_value stack_param'><span class='param'>...</span></td>";
            $Content .= "<td class='stack_value size4'>...</td>";
            $Content .= "</tr>\n";
        }
    }
    
    $Content .= "</table>\n";
    
    return $Content;
}

sub sortConv($$$)
{
    my ($Tid, $Conv, $VN) = @_;
    
    $Tid = get_PureType($Tid, $ABI{$VN});
    my %Type = %{$ABI{$VN}->{"TypeInfo"}{$Tid}};
    my %TMem = ();
    
    if(defined $Type{"Memb"})
    {
        foreach (sort {int($a)<=>int($b)} keys(%{$Type{"Memb"}}))
        {
            $TMem{$Type{"Memb"}{$_}{"name"}} = $_;
        }
    }
    
    my %Order = ();
    
    foreach my $Key (keys(%{$Conv}))
    {
        if($Key=~/\A(\.retval|\w+)\.(\w+)\Z/)
        { # .retval.a
          # p1.b
            $Order{$Key} = $TMem{$2};
        }
        else {
            $Order{$Key} = 0;
        }
    }
    
    return sort {int($Order{$a})<=>int($Order{$b})} keys(%{$Conv});
}

sub getMemType($$$)
{
    my ($Tid, $Mem, $VN) = @_;
    
    my ($FMem, $LMem) = ($Mem, "");
    
    if($Mem=~/\A(\w+)\.(.+)/) {
        ($FMem, $LMem) = ($1, $2);
    }
    
    $Tid = get_PureType($Tid, $ABI{$VN});
    my %Type = %{$ABI{$VN}->{"TypeInfo"}{$Tid}};
    
    if(defined $Type{"Memb"})
    {
        foreach my $P (sort {int($a)<=>int($b)} keys(%{$Type{"Memb"}}))
        {
            if($Type{"Memb"}{$P}{"name"} eq $FMem)
            {
                my $MTid = $Type{"Memb"}{$P}{"type"};
                if($LMem) {
                    return getMemType($MTid, $LMem, $VN);
                }
                else {
                    return $MTid;
                }
            }
        }
    }
    
    return undef;
}

sub getMemPos($$$)
{
    my ($Tid, $Mem, $VN) = @_;
    
    my %Type = %{$ABI{$VN}->{"TypeInfo"}{$Tid}};
    
    if(defined $Type{"Memb"})
    {
        foreach my $P (sort {int($a)<=>int($b)} keys(%{$Type{"Memb"}}))
        {
            if($Type{"Memb"}{$P}{"name"} eq $Mem)
            {
                return $P;
            }
        }
    }
    
    return undef;
}

sub showType(@)
{
    my $Tid = shift(@_);
    my $VN = shift(@_);
    
    # context of a type
    my $ID = undef;
    my $TID = undef;
    if(@_) {
        $ID = shift(@_); 
    }
    if(@_) {
        $TID = shift(@_);
    }
    
    my $NameSpace = undef;
    
    if($ID)
    {
        if(my $SymInfo = $ABI{$VN}->{"SymbolInfo"}{$ID})
        {
            if(defined $SymInfo->{"Class"}) {
                $NameSpace = $ABI{$VN}->{"TypeInfo"}{$SymInfo->{"Class"}}{"NameSpace"};
            }
            elsif(defined $SymInfo->{"NameSpace"}) {
                $NameSpace = $SymInfo->{"NameSpace"};
            }
        }
    }
    elsif($TID)
    {
        if(my $TypeInfo = $ABI{$VN}->{"TypeInfo"}{$TID}) {
            $NameSpace = $TypeInfo->{"NameSpace"};
        }
    }
    
    my %TInfo = %{$ABI{$VN}->{"TypeInfo"}{$Tid}};
    my $TName = $TInfo{"Name"};
    
    my $BTid = get_BaseType($Tid, $ABI{$VN}, "Const|Volatile|ConstVolatile|Restrict|Ref|RvalueRef|Array|Pointer");
    my %BTInfo = %{$ABI{$VN}->{"TypeInfo"}{$BTid}};
    
    if(keys(%TInfo)<=2
    or isPrivateABI($Tid, $VN)
    or keys(%BTInfo)<=2
    or isPrivateABI($BTid, $VN))
    { # incomplete info or private part of the ABI
        if($NameSpace) {
            $TName=~s/\b\Q$NameSpace\E\:\://g;
        }
        return htmlSpecChars($TName);
    }
    
    $TName = htmlSpecChars($TName);
    
    if($BTInfo{"Type"} ne "Intrinsic" and keys(%BTInfo)>2)
    {
        my $BTName = $BTInfo{"Name"};
        $BTName = rmQual($BTName);
        
        if($BTInfo{"Type"}=~/FuncPtr|MethodPtr|FieldPtr/)
        {
            my $FPtrName = showType($BTInfo{"Return"}, $VN, $ID, $TID);
            
            my @FParams = ();
            foreach (sort {int($a)<=>int($b)} keys(%{$BTInfo{"Param"}})) {
                push(@FParams, showType($BTInfo{"Param"}{$_}{"type"}, $VN, $ID, $TID));
            }
            
            if(my $Class = $BTInfo{"Class"}) {
                $FPtrName .= "(".showType($Class, $VN, $ID, $TID)."::*)";
            }
            else {
                $FPtrName .= "(*)";
            }
            
            $FPtrName .= "(".join(",&nbsp;", @FParams).")";
            
            return $FPtrName;
        }
        else
        {
            my $BTNameSp = htmlSpecChars($BTName);
            my $Title = getTypeTitle($BTid, $VN);
            my $Url = "../types/".getUname_T($BTid, $VN).".html";
            
            if(not $TName=~s&(\Q$BTNameSp\E)&<a href='$Url' title='$Title'>$1</a>&)
            {
                $Title = getTypeTitle($Tid, $VN);
                $TName = "<a href='../types/".getUname_T($Tid, $VN).".html'>$TName</a>";
            }
        }
    }
    
    if($NameSpace) {
        $TName=~s/\b\Q$NameSpace\E\:\://g;
    }
    
    return $TName;
}

sub getTypeTitle($$)
{
    my ($Tid, $VN) = @_;
    
    my %TInfo = %{$ABI{$VN}->{"TypeInfo"}{$Tid}};
    
    if($TInfo{"Type"} eq "Typedef")
    {
        my $Bid = $TInfo{"BaseType"};
        return "typedef to ".$ABI{$VN}->{"TypeInfo"}{$Bid}{"Name"};
    }
    
    return "";
}

sub showRegisters($$)
{
    my ($ID, $VN) = @_;
    my %Info = %{$ABI{$VN}->{"SymbolInfo"}{$ID}};
    
    my $Content = "";
    
    $Content .= "<table cellpadding='3' class='stack_frame'>\n";
    
    $Content .= "<tr>";
    $Content .= "<th>Name</th>";
    $Content .= "<th>Contents</th>";
    $Content .= "<th>Type</th>";
    $Content .= "</tr>\n";
    
    my $Used = 0;
    
    if(my $Rid = $Info{"Return"})
    {
        my $RConv = getCallConv_R($ID, $ABI{$VN});
        foreach my $RSubj (sortConv($Rid, $RConv, $VN))
        {
            my $RPassed = $RConv->{$RSubj};
            
            if($RPassed and $RPassed!~/stack/)
            {
                my $Size = $ABI{$VN}->{"TypeInfo"}{$Rid}{"Size"};
                my $TS = "";
                my $Mid = $Rid;
                
                if($RSubj eq ".result_ptr")
                {
                    $Size = $ABI{$VN}->{"WordSize"};
                    $TS = "*";
                }
                elsif($RSubj=~/\.retval\.(.+)\Z/)
                {
                    if($Mid = getMemType($Rid, $1, $VN)) {
                        $Size = $ABI{$VN}->{"TypeInfo"}{$Mid}{"Size"};
                    }
                }
                
                my $C = "stack_return";
                if(defined $PsetStatus{$VN}{$ID}{$RSubj}{"Added"}) {
                    $C = "added";
                }
                elsif(defined $PsetStatus{$VN}{$ID}{$RSubj}{"Removed"}) {
                    $C = "removed";
                }
                
                $Content .= "<tr>\n";
                $Content .= "<td class='stack_offset'>%$RPassed</td>";
                $Content .= "<td class=\'stack_value $C\'><span class='retval'>$RSubj</span></td>";
                my $SType = showType($Mid, $VN, $ID).$TS;
                if(defined $PsetStatus{$VN}{$ID}{$RSubj}{"ChangedType"})
                {
                    if($VN==1) {
                        $SType = "<span class='replace_l'>".$SType."</span>";
                    }
                    else {
                        $SType = "<span class='added_l'>".$SType."</span>";
                    }
                }
                $Content .= "<td class='stack_value' ".showHeight($Size).">".$SType."</td>";
                $Content .= "</tr>\n";
                
                $Used = 1;
            }
        }
    }
    
    foreach my $Pos (sort {int($a)<=>int($b)} keys(%{$Info{"Param"}}))
    {
        my %PInfo = %{$Info{"Param"}{$Pos}};
        my $Tid = $PInfo{"type"};
        my %TInfo = %{$ABI{$VN}->{"TypeInfo"}{$Tid}};
        
        if(my $PConv = getCallConv_P($ID, $ABI{$VN}, $Pos))
        {
            foreach my $PSubj (sortConv($Tid, $PConv, $VN))
            {
                my $PPassed = $PConv->{$PSubj};
                
                if($PPassed and $PPassed!~/stack/)
                {
                    my $Size = $ABI{$VN}->{"TypeInfo"}{$Tid}{"Size"};
                    my $Mid = $Tid;
                    
                    if($PSubj=~/\.(\w+)\Z/)
                    {
                        $Mid = getMemType($Tid, $1, $VN);
                        $Size = $ABI{$VN}->{"TypeInfo"}{$Mid}{"Size"};
                    }
                    
                    my $C = "stack_param";
                    if(defined $PsetStatus{$VN}{$ID}{$PSubj}{"Added"}) {
                        $C = "added";
                    }
                    elsif(defined $PsetStatus{$VN}{$ID}{$PSubj}{"Removed"}) {
                        $C = "removed";
                    }
                    
                    $Content .= "<tr>";
                    $Content .= "<td class='stack_offset'>%$PPassed</td>";
                    $Content .= "<td class='stack_value $C".showName($PSubj, $Size)."'><span class='param'>".$PSubj."</span></td>";
                    
                    my $SType = showType($Mid, $VN, $ID);
                    if(defined $PsetStatus{$VN}{$ID}{$PSubj}{"ChangedType"})
                    {
                        if($VN==1) {
                            $SType = "<span class='replace_l'>".$SType."</span>";
                        }
                        else {
                            $SType = "<span class='added_l'>".$SType."</span>";
                        }
                    }
                    
                    $Content .= "<td class='stack_value' ".showHeight($Size).">".$SType."</td>";
                    $Content .= "</tr>\n";
                    
                    $Used = 1;
                }
            }
        }
    }
    
    $Content .= "</table>\n";
    
    if(not $Used) {
        return "Not used to pass parameters or return value.<br/>";
    }
    
    return $Content;
}

sub showBytes($)
{
    if($_[0]==1) {
        return "byte";
    }
    
    return "bytes";
}

sub showVTable($$)
{
    my ($CId, $VN) = @_;
    
    my $NameSpace = $ABI{$VN}->{"TypeInfo"}{$CId}{"NameSpace"};
    
    my %VTable = %{$ABI{$VN}->{"TypeInfo"}{$CId}{"VTable"}};
    
    my $Content = "";
    
    $Content .= "<table cellpadding='3' class='summary stack_frame'>\n";
    
    $Content .= "<tr>";
    $Content .= "<th>Offset</th>";
    $Content .= "<th>Contents</th>";
    $Content .= "</tr>\n";
    
    foreach my $Offset (sort {int($a)<=>int($b)} keys(%VTable))
    {
        my $Val = $VTable{$Offset};
        my $Sym = "";
        
        if($Val=~s/\s+\[(.+)\]\Z//) {
            $Sym = $1;
        }
        
        $Val=~s/\A\Q(int (*)(...))\E //;
        $Val=~s/\A\((.+)\)\Z/$1/;
        
        if(isTInfo($Sym) and $Val=~/typeinfo for (.+)\Z/)
        {
            my $Class = $1;
            
            $Val = htmlSpecChars($Val);
            
            if(defined $TypeID{$VN}{$Class})
            {
                my $ClassId = $TypeID{$VN}{$Class};
                my $ClassSp = htmlSpecChars($Class);
                my $Url = "../types/".getUname_T($ClassId, $VN).".html";
                
                $Val=~s&(\Q$ClassSp\E)&<a href='$Url'>$1</a>&;
            }
        }
        else
        {
            $Val = htmlSpecChars($Val);
            
            if(defined $SymbolID{$VN}{$Sym})
            {
                my $ClassId = $ABI{$VN}->{"SymbolInfo"}{$SymbolID{$VN}{$Sym}}{"Class"};
                my $Class = $ABI{$VN}->{"TypeInfo"}{$ClassId}{"Name"};
                my $ClassSp = htmlSpecChars($Class);
                my $Url = "../types/".getUname_T($ClassId, $VN).".html";
                
                $Val=~s&\A(\Q$ClassSp\E)(\:\:)&<a href='$Url'>$1</a>$2&;
            }
        }
        
        if($NameSpace) {
            $Val=~s/\b\Q$NameSpace\E\:\://g;
        }
        
        $Content .= "<tr>";
        $Content .= "<td class='stack_offset'>$Offset</td>";
        
        if($Sym) {
            $Content .= "<td class='stack_value short45 size4 vtable_func'>".$Val."</td>";
        }
        else {
            $Content .= "<td class='stack_value short45 size4 vtable_other'>".$Val."</td>";
        }
        $Content .= "</tr>\n";
    }
    
    $Content .= "</table>\n";
    $Content .= "<br/>";
    
    return $Content;
}

sub isVTable($)
{
    if(index($_[0], "_ZTV")==0) {
        return 1;
    }
    
    return 0;
}

sub isTInfo($)
{
    if(index($_[0], "_ZTI")==0) {
        return 1;
    }
    
    return 0;
}

sub isStd($)
{
    my $Name = $_[0];
    
    if($Name=~/\A(_ZS|_ZNS|_ZNKS|_ZN9__gnu_cxx|_ZNK9__gnu_cxx|_ZTIS|_ZTSS|_Zd|_Zn)/) {
        return 1;
    }
    
    return 0;
}

sub isStdNS($)
{
    my $NS = $_[0];
    
    if($NS=~/\A(std|__gnu_cxx)\Z/) {
        return 1;
    }
    
    return 0;
}

sub isStdType($)
{
    my $Name = $_[0];
    
    if($Name=~/\A(struct |class |union |enum |)(\w+)::/)
    {
        if(isStdNS($2)) {
            return 1;
        }
    }
    
    return 0;
}

sub getMd5(@) {
    return substr(md5_hex(@_), 0, $MD5_LEN);
}

sub getUname_T($$)
{
    my ($ID, $VN) = @_;
    
    return getMd5($ABI{$VN}->{"TypeInfo"}{$ID}{"Name"});
}

sub showTypeList()
{
    printMsg("INFO", "Create types list");
    
    my @Names = keys(%{$TypeID{1}});
    
    if(defined $Diff)
    {
        foreach my $Name (keys(%AddedTypes)) {
            push(@Names, $Name);
        }
    }
    
    my %TypeName_Order = ();
    my %TypeName = ();
    
    foreach my $Name (@Names)
    {
        my $VN = 1;
        if(defined $AddedTypes{$Name}) {
            $VN = 2;
        }
        
        my $TID = $TypeID{$VN}{$Name};
        my %TInfo = %{$ABI{$VN}->{"TypeInfo"}{$TID}};
        
        if(not selectType($TID, $VN)) {
            next;
        }
        
        if(not $TInfo{"Source"}
        and not $TInfo{"Header"}) {
            next;
        }
        
        if(defined $SkipStd)
        {
            if(isStdNS($TInfo{"NameSpace"})
            or isStdType($Name))
            {
                next;
            }
        }
        
        my $N = rmQual($Name);
        $TypeName{$Name} = $N;
        
        my $NameSpace = $ABI{$VN}->{"TypeInfo"}{$TID}{"NameSpace"};
        if($NameSpace) {
            $N=~s/\b\Q$NameSpace\E\:\://g;
        }
        $TypeName_Order{$Name} = $N;
    }
    
    @Names = sort {lc($TypeName{$a}) cmp lc($TypeName{$b})} keys(%TypeName);
    @Names = sort {lc($TypeName_Order{$a}) cmp lc($TypeName_Order{$b})} @Names;
    
    my $Content = composeHTML_Head("Types List", $ABI{1}->{"LibraryName"}.", types, attributes", $ABI{1}->{"LibraryName"}.": List of types", getTop("types"), "report.css", "sort.js");
    $Content .= "<body>\n";
    
    $Content .= showMenu("types");
    $Content .= "<h1>Types List (".($#Names+1).")</h1>\n";
    $Content .= "<br/>\n";
    
    # legend
    my $Legend = "";
    $Legend .= "<table class='summary symbols_legend'>";
    $Legend .= "<tr><td class='class'>CLASS</td><td class='enum'>ENUM</td></tr>";
    $Legend .= "<tr><td class='union'>UNION</td><td class='struct'>STRUCT</td></tr>";
    $Legend .= "</table>";
    
    if($Diff)
    {
        $Content .= "<table cellpadding='0' cellspacing='0'>\n";
        $Content .= "<tr>\n";
        
        $Content .= "<td valign='top'>\n";
        $Content .= $Legend;
        $Content .= "</td>\n";
        
        $Content .= "<td width='20px;'>\n";
        $Content .= "</td>\n";
        
        $Content .= "<td valign='top'>\n";
        # legend
        $Content .= "<table class='summary symbols_legend'>";
        if(my $Added = keys(%AddedTypes)) {
            $Content .= "<tr><td class='added sort' onclick=\"javascript:statusFilter('ADDED')\">ADDED</td><td class='legend_num'>$Added</td></tr>";
        }
        else {
            $Content .= "<tr><td class='added'>ADDED</td><td class='legend_num'>0</td></tr>";
        }
        if(my $Removed = keys(%RemovedTypes)) {
            $Content .= "<tr><td class='removed sort' onclick=\"javascript:statusFilter('REMOVED')\">REMOVED</td><td class='legend_num'>$Removed</td></tr>";
        }
        else {
            $Content .= "<tr><td class='removed'>REMOVED</td><td class='legend_num'>0</td></tr>";
        }
        if(my $Changed = keys(%ChangedTypes)) {
            $Content .= "<tr><td class='changed sort' onclick=\"javascript:statusFilter('CHANGED')\">CHANGED</td><td class='legend_num'>$Changed</td></tr>";
        }
        else {
            $Content .= "<tr><td class='changed'>CHANGED</td><td class='legend_num'>0</td></tr>";
        }
        $Content .= "</table>";
        $Content .= "</td>\n";
        
        $Content .= "</tr>\n";
        $Content .= "</table>\n";
    }
    else
    {
        $Content .= $Legend;
    }
    
    $Content .= "<br/>\n";
    $Content .= "<br/>\n";
    
    # list
    my $Sort = "class='sort' onclick='sort(this)'";
    
    $Content .= "<table id='List' cellpadding='3' class='summary'>\n";
    $Content .= "<tr>\n";
    $Content .= "<th $Sort title='sort by Name'>Name</th>\n";
    
    if(defined $Diff) {
        $Content .= "<th $Sort title='sort by Status'>Status</th>\n";
    }
    
    $Content .= "<th $Sort title='sort by Type'>Type</th>\n";
    $Content .= "<th $Sort title='sort by Fields'>Fields</th>\n";
    $Content .= "<th $Sort title='sort by Source'>Source</th>\n";
    $Content .= "<th $Sort title='sort by Size'>Size</th>\n";
    $Content .= "<th $Sort title='sort by Usage'>Usage</th>\n";
    
    $Content .= "</tr>\n";
    
    foreach my $Name (@Names)
    {
        my $VN = 1;
        if(defined $AddedTypes{$Name}) {
            $VN = 2;
        }
        
        my $TID = $TypeID{$VN}{$Name};
        my %TInfo = %{$ABI{$VN}->{"TypeInfo"}{$TID}};
        
        my $Type = $TInfo{"Type"};
        
        my $Source = $TInfo{"Source"};
        if(not $Source) {
            $Source = $TInfo{"Header"};
        }
        
        $Content .= "<tr>\n";
        
        # name
        $Content .= "<td valign='top' class='short'>".htmlSpecChars(rmQual($Name))." <a class='info' href='types/".getUname_T($TID, $VN).".html'>&raquo;</a></td>\n";
        
        if(defined $Diff)
        {
            # status
            if(defined $AddedTypes{$Name}) {
                $Content .= "<td class='added'>ADDED</td>\n";
            }
            elsif(defined $RemovedTypes{$Name}) {
                $Content .= "<td class='removed'>REMOVED</td>\n";
            }
            elsif(defined $ChangedTypes{$Name}) {
                $Content .= "<td class='changed'>CHANGED</td>\n";
            }
            else {
                $Content .= "<td align='center'></td>\n";
            }
        }
        
        # type
        $Content .= "<td class='".lc($Type)."'>".uc($Type)."</td>\n";
        
        # total fields
        if($Type=~/Class|Struct|Union|Enum/)
        {
            if(defined $TInfo{"Memb"})
            {
                my $MNum = keys(%{$TInfo{"Memb"}});
                
                if($MNum) {
                    $Content .= "<td><a href='types/".getUname_T($TID, $VN).".html#Fields'>".$MNum."</a></td>\n";
                }
                else {
                    $Content .= "<td>0</td>\n";
                }
            }
            else {
                $Content .= "<td>0</td>\n";
            }
        }
        else {
            $Content .= "<td></td>\n";
        }
        
        # source
        $Content .= "<td class='short14'>".$Source."</td>\n";
        
        # size
        $Content .= "<td>".$TInfo{"Size"}."</td>\n";
        
        # usage
        if(my $Used = countUsage($TID, $VN)) {
            $Content .= "<td><a href='usage/".getUname_T($TID, $VN).".html'>$Used</a></td>\n";
        }
        else {
            $Content .= "<td>0</td>\n";
        }
        
        $Content .= "</tr>\n";
    }
    $Content .= "</table>\n";
    
    if($SHOW_DEV) {
        $Content .= getSign();
    }
    
    $Content .= "</body>\n";
    $Content .= "</html>\n";
    
    writeFile($Output."/types.html", $Content);
}

sub isPrivateABI($$)
{
    my ($TID, $VN) = @_;
    
    if(defined $ShowPrivateABI) {
        return 0;
    }
    
    if(defined $ABI{$VN}->{"TypeInfo"}{$TID}{"PrivateABI"})
    { # private part of the ABI
        return 1;
    }
    
    return 0;
}

sub selectType($$)
{
    my ($TID, $VN) = @_;
    
    if(keys(%{$ABI{$VN}->{"TypeInfo"}{$TID}})<=2)
    { # incomplete info
        return 0;
    }
    
    if(isPrivateABI($TID, $VN)) {
        return 0;
    }
    
    if($ABI{$VN}->{"TypeInfo"}{$TID}{"Type"}!~/\A(Class|Struct|Union|Enum)\Z/) {
        return 0;
    }
    
    return 1;
}

sub detectAddedRemoved()
{
    foreach my $Name (keys(%{$SymbolID{1}}))
    {
        if(not defined $SymbolID{2}{$Name}) {
            $RemovedSymbols{$Name} = 1;
        }
    }
    
    foreach my $Name (keys(%{$SymbolID{2}}))
    {
        if(not defined $SymbolID{1}{$Name}) {
            $AddedSymbols{$Name} = 1;
        }
    }
    
    foreach my $Name (keys(%{$TypeID{1}}))
    {
        my $TID = $TypeID{1}{$Name};
        
        my $PairTid = undef;
        
        if(defined $TypeID{2}{$Name}) {
            $PairTid = $TypeID{2}{$Name};
        }
        else
        {
            if(index($Name, "anon-")==0)
            {
                if(my @Types = keys(%{$TypeMemb{1}{$TID}}))
                {
                    my $ETid = $Types[0];
                    my $TN = getTypeName($ETid, 1);
                    
                    if(my @Fields = keys(%{$TypeMemb{1}{$TID}{$ETid}}))
                    {
                        my $Field = $Fields[0];
                        
                        if(defined $TypeID{2}{$TN})
                        {
                            my $T = $ABI{2}->{"TypeInfo"}{$TypeID{2}{$TN}};
                            
                            foreach my $P (sort keys(%{$T->{"Memb"}}))
                            {
                                if($T->{"Memb"}{$P}{"name"} eq $Field)
                                {
                                    $PairTid = $T->{"Memb"}{$P}{"type"};
                                    last;
                                }
                            }
                        }
                    }
                }
            }
        }
        
        if($PairTid)
        {
            $MappedType{$TID} = $PairTid;
            $MappedType_R{$PairTid} = $TID;
        }
        else
        {
            if(selectType($TID, 1)) {
                $RemovedTypes{$Name} = 1;
            }
            
            $RemovedTypes_All{$Name} = 1;
        }
    }
    
    foreach my $Name (keys(%{$TypeID{2}}))
    {
        my $TID = $TypeID{2}{$Name};
        
        if(not defined $TypeID{1}{$Name}
        and not defined $MappedType_R{$TID})
        {
            if(selectType($TID, 2)) {
                $AddedTypes{$Name} = 1;
            }
            
            $AddedTypes_All{$Name} = 1;
        }
    }
}

sub showSymbolList()
{
    printMsg("INFO", "Create symbols list");
    
    my @Names = keys(%{$SymbolID{1}});
    
    if($Diff)
    {
        foreach my $Name (keys(%AddedSymbols)) {
            push(@Names, $Name);
        }
    }
    
    # filter symbols
    my @Filt = ();
    foreach my $Symbol (@Names)
    {
        my $VN = 1;
        if(defined $AddedSymbols{$Symbol}) {
            $VN = 2;
        }
        
        my $ID = $SymbolID{$VN}{$Symbol};
        my %Info = %{$ABI{$VN}->{"SymbolInfo"}{$ID}};
        
        my $Name = $Info{"MnglName"};
        if(not $Name) {
            $Name = $Info{"ShortName"};
        }
        
        if(defined $SkipStd and isStd($Name)) {
            next;
        }
        
        if(not $Info{"Bind"}) {
            next;
        }
        
        push(@Filt, $Name);
    }
    
    @Names = sort {lc($a) cmp lc($b)} @Filt;
    @Names = sort {lc($Sort_Symbols{$a}) cmp lc($Sort_Symbols{$b})} @Names;
    
    my $Content = composeHTML_Head("Symbols List", $ABI{1}->{"LibraryName"}.", symbols, attributes", $ABI{1}->{"LibraryName"}.": List of symbols", getTop("symbols"), "report.css", "sort.js");
    $Content .= "<body>\n";
    
    $Content .= showMenu("symbols");
    $Content .= "<h1>Symbols List (".($#Names + 1).")</h1>\n";
    $Content .= "<br/>\n";
    
    # legend
    my $Legend = "";
    $Legend .= "<table class='summary symbols_legend'>";
    $Legend .= "<tr><td class='func'>FUNC</td><td class='obj'>OBJ</td></tr>";
    $Legend .= "<tr><td class='weak'>WEAK</td><td class='global'>GLOBAL</td></tr>";
    $Legend .= "</table>";
    
    if($Diff)
    {
        $Content .= "<table cellpadding='0' cellspacing='0'>\n";
        $Content .= "<tr>\n";
        
        $Content .= "<td valign='top'>\n";
        $Content .= $Legend;
        $Content .= "</td>\n";
        
        $Content .= "<td width='20px;'>\n";
        $Content .= "</td>\n";
        
        $Content .= "<td valign='top'>\n";
        # legend
        $Content .= "<table class='summary symbols_legend'>";
        if(my $Added = keys(%AddedSymbols)) {
            $Content .= "<tr><td class='added sort' onclick=\"javascript:statusFilter('ADDED')\">ADDED</td><td class='legend_num'>$Added</td></tr>";
        }
        else {
            $Content .= "<tr><td class='added'>ADDED</td><td class='legend_num'>0</td></tr>";
        }
        if(my $Removed = keys(%RemovedSymbols)) {
            $Content .= "<tr><td class='removed sort' onclick=\"javascript:statusFilter('REMOVED')\">REMOVED</td><td class='legend_num'>$Removed</td></tr>";
        }
        else {
            $Content .= "<tr><td class='removed'>REMOVED</td><td class='legend_num'>0</td></tr>";
        }
        if(my $Changed = keys(%ChangedSymbols)) {
            $Content .= "<tr><td class='changed sort' onclick=\"javascript:statusFilter('CHANGED')\">CHANGED</td><td class='legend_num'>$Changed</td></tr>";
        }
        else {
            $Content .= "<tr><td class='changed'>CHANGED</td><td class='legend_num'>0</td></tr>";
        }
        $Content .= "</table>";
        $Content .= "</td>\n";
        
        $Content .= "</tr>\n";
        $Content .= "</table>\n";
    }
    else
    {
        $Content .= $Legend;
    }
    
    $Content .= "<br/>\n";
    $Content .= "<br/>\n";
    
    # list
    my $Sort = "class='sort' onclick='sort(this)'";
    
    $Content .= "<table id='List' cellpadding='3' class='summary'>\n";
    $Content .= "<tr>\n";
    $Content .= "<th $Sort title='sort by Name'>Name</th>\n";
    $Content .= "<th>Signature</th>\n";
    
    if(defined $Diff) {
        $Content .= "<th $Sort title='sort by Status'>Status</th>\n";
    }
    
    $Content .= "<th $Sort title='sort by Type'>Type</th>\n";
    $Content .= "<th $Sort title='sort by Params'>Prms</th>\n";
    $Content .= "<th $Sort title='sort by Return'>Return</th>\n";
    $Content .= "<th $Sort title='sort by Source'>Source</th>\n";
    # $Content .= "<th $Sort title='sort by Value'>Value</th>\n";
    $Content .= "<th $Sort title='sort by Size'>Size</th>\n";
    $Content .= "<th $Sort title='sort by Bind'>Bind</th>\n";
    $Content .= "<th $Sort title='sort by Vis'>Vis</th>\n";
    $Content .= "<th $Sort title='sort by Ndx'>Ndx</th>\n";
    $Content .= "</tr>\n";
    
    foreach my $Symbol (@Names)
    {
        my $VN = 1;
        if(defined $AddedSymbols{$Symbol}) {
            $VN = 2;
        }
        
        my $ID = $SymbolID{$VN}{$Symbol};
        my %Info = %{$ABI{$VN}->{"SymbolInfo"}{$ID}};
        
        my $Name = $Info{"MnglName"};
        if(not $Name) {
            $Name = $Info{"ShortName"};
        }
        
        my $Kind = $Info{"Kind"};
        if($Kind eq "OBJECT") {
            $Kind = "OBJ";
        }
        
        my $CId = $Info{"Class"};
        my $NameSpace = $ABI{$VN}->{"TypeInfo"}{$CId}{"NameSpace"};
        
        $Content .= "<tr>\n";
        
        # name
        $Content .= "<td valign='top' class='short_S'>".$Name." <a class='info' href='symbols/$Symbol.html'>&raquo;</a></td>\n";
        
        # signature
        my $Sig = get_Signature(\%Info, $VN, 1, 1, undef);
        $Content .= "<td valign='top' class='short'>".$Sig."</td>\n";
        
        if(defined $Diff)
        {
            # status
            if(defined $AddedSymbols{$Name}) {
                $Content .= "<td class='added'>ADDED</td>\n";
            }
            elsif(defined $RemovedSymbols{$Name}) {
                $Content .= "<td class='removed'>REMOVED</td>\n";
            }
            elsif(defined $ChangedSymbols{$Name}) {
                $Content .= "<td class='changed'>CHANGED</td>\n";
            }
            else {
                $Content .= "<td align='center'></td>\n";
            }
        }
        
        # kind
        $Content .= "<td class='".lc($Kind)."'>".$Kind."</td>\n";
        
        # total parameters
        if($Kind eq "OBJ") {
            $Content .= "<td></td>\n";
        }
        else
        {
            if(defined $Info{"Param"})
            {
                my $PNum = keys(%{$Info{"Param"}});
                
                if(defined $Info{"Class"}
                and not defined $Info{"Static"}) {
                    $PNum-=1;
                }
                
                if($PNum) {
                    $Content .= "<td><a href='symbols/$Symbol.html'>".$PNum."</a></td>\n";
                }
                else {
                    $Content .= "<td>0</td>\n";
                }
            }
            else {
                $Content .= "<td>0</td>\n";
            }
        }
        
        # return
        my $Rid = $Info{"Return"};
        my $Return = $ABI{$VN}->{"TypeInfo"}{$Rid}{"Name"};
        $Return=~s/\b\Q$NameSpace\E\:\://g;
        $Content .= "<td class='short18'>".htmlSpecChars(simpleName($Return))."</td>\n";
        
        # source
        my $Source = $Info{"Source"};
        if(not $Source) {
            $Source = $Info{"Header"};
        }
        $Content .= "<td class='short14'>".$Source."</td>\n";
        
        # value
        my $Val = $Info{"Val"};
        if(length($Val)==16) {
            $Val=~s/\A00000000//g
        }
        #$Content .= "<td>".$Val."</td>\n";
        
        # attrs
        $Content .= "<td>".$Info{"Size"}."</td>\n";
        $Content .= "<td class='".lc($Info{"Bind"})."'>".$Info{"Bind"}."</td>\n";
        $Content .= "<td>".$Info{"Vis"}."</td>\n";
        $Content .= "<td>".$Info{"Ndx"}."</td>\n";
        
        $Content .= "</tr>\n";
    }
    $Content .= "</table>\n";
    
    if($SHOW_DEV) {
        $Content .= getSign();
    }
    
    $Content .= "</body>\n";
    $Content .= "</html>\n";
    
    writeFile($Output."/symbols.html", $Content);
}

sub htmlSpecChars(@)
{
    my $Str = shift(@_);
    my $Sp = undef;
    
    if(@_) {
        $Sp = shift(@_);
    }
    
    $Str=~s/\&/&amp;/g;
    $Str=~s/</&lt;/g;
    $Str=~s/\-\>/&#45;&gt;/g; # &minus;
    $Str=~s/>/&gt;/g;
    $Str=~s/\n/<br\/>/g;
    $Str=~s/\"/&quot;/g;
    $Str=~s/\'/&#39;/g;
    
    if(not defined $Sp) {
        $Str=~s/ /&nbsp;/g;
    }
    
    return $Str;
}

sub simpleName($)
{
    my $Name = $_[0];
    
    $Name=~s/std::basic_string<char>(\w)/std::string $1/g;
    $Name=~s/std::basic_string<char>(\W)/std::string$1/g;
    
    return $Name;
}

sub get_Signature_FP($$$)
{
    my ($Info, $VN, $TargetPos) = @_;
    
    my $Return = $Info->{"Return"};
    my $Sig = "";
    
    if($TargetPos eq "ret") {
        $Sig .= "<span class='highlighted'>".$ABI{$VN}->{"TypeInfo"}{$Return}{"Name"}."</span>";
    }
    else {
        $Sig .= $ABI{$VN}->{"TypeInfo"}{$Return}{"Name"};
    }
    
    my $NameSpace = $Info->{"NameSpace"};
    
    if(my $Class = $Info->{"Class"})
    {
        my $CName = $ABI{$VN}->{"TypeInfo"}{$Class}{"Name"};
        if($NameSpace) {
            $CName=~s/\b\Q$NameSpace\E\:\://g;
        }
        
        $Sig .= "(".$CName."::*)";
    }
    else {
        $Sig .= "(*)";
    }
    
    my @Param = ();
    my @Pos = sort {int($a)<=>int($b)} keys(%{$Info->{"Param"}});
    
    foreach my $P (@Pos)
    {
        my $Tid = $Info->{"Param"}{$P}{"type"};
        my $TName = $ABI{$VN}->{"TypeInfo"}{$Tid}{"Name"};
        
        if($NameSpace) {
            $TName=~s/\b\Q$NameSpace\E\:\://g;
        }
        
        $TName = simpleName($TName);
        $TName = htmlSpecChars($TName);
        
        my $Comma = ",";
        if($P==$#Pos) {
            $Comma = "";
        }
        
        if(defined $TargetPos
        and $P eq $TargetPos) {
            push(@Param, "<span class='highlighted'>".$TName."</span>".$Comma);
        }
        else {
            push(@Param, $TName.$Comma);
        }
    }
    
    if(@Param)
    {
        my $Sp = "&nbsp;&nbsp;&nbsp;&nbsp;";
        $Sig .= "&nbsp;{<br/>".$Sp.join("<br/>\n".$Sp, @Param)."<br/>}";
    }
    
    return $Sig;
}

sub get_Signature_T($$$)
{
    my ($Info, $VN, $TargetMemb) = @_;
    
    my $Sig = htmlSpecChars($Info->{"Name"});
    my $NameSpace = $Info->{"NameSpace"};
    
    my @Memb = ();
    my @Pos = sort {int($a)<=>int($b)} keys(%{$Info->{"Memb"}});
    my $Target = undef;
    
    foreach my $P (@Pos)
    {
        my $Tid = $Info->{"Memb"}{$P}{"type"};
        my $TName = $ABI{$VN}->{"TypeInfo"}{$Tid}{"Name"};
        my $MName = $Info->{"Memb"}{$P}{"name"};
        
        if($NameSpace) {
            $TName=~s/\b\Q$NameSpace\E\:\://g;
        }
        
        $TName = simpleName($TName);
        $TName = htmlSpecChars($TName);
        my $C = "param";
        if($TargetMemb
        and $MName eq $TargetMemb)
        {
            $C .= " highlighted";
            $Target = $P;
        }
        my $Comma = ",";
        if($P==$#Pos) {
            $Comma = "";
        }
        
        push(@Memb, $TName."&nbsp;<span class=\'$C\'>".$MName."</span>".$Comma);
    }
    
    my $MX_SIZE = 10;
    
    if(@Pos>$MX_SIZE)
    {
        if($Target>$MX_SIZE) {
            splice(@Memb, 0, $Target-2, ("..."));
            $Target = 3;
        }
        
        if($#Memb - $Target>$MX_SIZE) {
            splice(@Memb, $Target+3, $#Memb - $Target, ("..."));
        }
    }
    
    if(@Memb)
    {
        my $Sp = "&nbsp;&nbsp;&nbsp;&nbsp;";
        $Sig .= "&nbsp;{<br/>".$Sp.join("<br/>\n".$Sp, @Memb)."<br/>}";
    }
    
    return $Sig;
}

sub get_Signature($$$$$)
{
    my ($Info, $VN, $Highlight, $Attrs, $TargetParam) = @_;
    
    my $Sig = "";
    
    my $CId = $Info->{"Class"};
    my $CName = "";
    my $NameSpace = "";
    
    if($CId)
    {
        $CName = $ABI{$VN}->{"TypeInfo"}{$CId}{"Name"};
        $NameSpace = $ABI{$VN}->{"TypeInfo"}{$CId}{"NameSpace"};
        $CName=~s/\b\Q$NameSpace\E\:\://g;
    }
    
    my $Kind = $Info->{"Kind"};
    
    if($Kind eq "OBJECT")
    {
        if(isVTable($Info->{"MnglName"}))
        { # v-table
            $Sig = "vtable for ".$CName;
        }
        else
        { # data
            $Sig = $Info->{"ShortName"};
        }
        
        if($Highlight) {
            $Sig = htmlSpecChars($Sig);
        }
        
        return $Sig;
    }
    
    if($CName)
    {
        if($Highlight) {
            $Sig .= htmlSpecChars($CName)."::";
        }
        else {
            $Sig .= $CName."::";
        }
        
        if(defined $Info->{"Destructor"})
        {
            $Sig .= "~";
        }
    }
    
    if($Highlight) {
        $Sig .= htmlSpecChars($Info->{"ShortName"});
    }
    else {
        $Sig .= $Info->{"ShortName"};
    }
    
    if(not $Info->{"Data"})
    {
        my @Param = ();
        
        if(defined $Info->{"Param"})
        {
            foreach my $Pos (sort {int($a)<=>int($b)} keys(%{$Info->{"Param"}}))
            {
                my $Tid = $Info->{"Param"}{$Pos}{"type"};
                my $TName = $ABI{$VN}->{"TypeInfo"}{$Tid}{"Name"};
                my $PName = $Info->{"Param"}{$Pos}{"name"};
                
                if($NameSpace) {
                    $TName=~s/\b\Q$NameSpace\E\:\://g;
                }
                
                if($PName eq "this") { # do not show?
                    next;
                }
                
                $TName = simpleName($TName);
                
                if($Highlight)
                {
                    $TName = htmlSpecChars($TName);
                    my $C = "param";
                    if($TargetParam
                    and $PName eq $TargetParam) {
                        $C .= " highlighted";
                    }
                    push(@Param, $TName."&nbsp;<span class=\'$C\'>".$PName."</span>");
                }
                else {
                    push(@Param, $TName." ".$PName);
                }
            }
        }
        
        if($Highlight)
        {
            if(@Param)
            {
                my $Sp = "&nbsp;&nbsp;&nbsp;&nbsp;";
                $Sig .= "&nbsp;(<br/>".$Sp.join(",<br/>\n".$Sp, @Param)."<br/>)";
            }
            else {
                $Sig .= "&nbsp;(&nbsp;)";
            }
        }
        else
        {
            if(@Param) {
                $Sig .= " ( ".join(", ", @Param)." )";
            }
            else {
                $Sig .= " ( )";
            }
        }
    }
    
    if($Attrs)
    {
        # show charge level?
        if(defined $Info->{"Constructor"} or defined $Info->{"Destructor"})
        {
            $Sig .= " ";
            
            if($Highlight) {
                $Sig .= "<span class='charge'>".get_Charge($Info->{"MnglName"})."</span>";
            }
            else {
                $Sig .= get_Charge($Info->{"MnglName"});
            }
        }
        elsif(defined $Info->{"Static"})
        {
            $Sig .= " ";
            
            if($Highlight) {
                $Sig .= "<span class='static'>[static]</span>";
            }
            else {
                $Sig .= "[static]";
            }
        }
        elsif(defined $Info->{"Const"})
        {
            $Sig .= " ";
            
            if($Highlight) {
                $Sig .= "<span class='const'>[const]</span>";
            }
            else {
                $Sig .= "[const]";
            }
        }
    }
    
    return $Sig;
}

sub checkInput($$)
{
    my ($Path, $VN) = @_;
    
    if(-d $Path)
    {
        if(not -f $Path."/ABI.dump") {
            exitStatus("Error", "incorrect format of input data (ABI.dump is not found)");
        }
        if(not -d $Path."/debug") {
            exitStatus("Error", "incorrect format of input data (debug data is not found)");
        }
        return $Path."/ABI.dump";
    }
    elsif(isDump($Path))
    {
        return $Path;
    }
    else
    {
        if(isElf($Path))
        { # create ABI dump
            return createDump($Path, $VN);
        }
        else {
            exitStatus("Error", "input file should be ABI dump or shared object");
        }
    }
}

sub isDump($) {
    return $_[0]=~/\.dump\Z/;
}

sub createDump($)
{
    my ($Path, $VN) = @_;
    
    if($Diff) {
        printMsg("INFO", "Create ABI.dump ($VN)");
    }
    else {
        printMsg("INFO", "Create ABI.dump");
    }
    
    my $Cmd = $ABI_DUMPER." \"".$Path."\" -o \"".$EXTRA{$VN}."/ABI.dump\" -extra-info \"".$EXTRA{$VN}."/debug\" -extra-dump";
    
    if(defined $TargetVersion1) {
        $Cmd .= " -lver \"".$TargetVersion1."\"";
    }
    else
    {
        my $Ver = undef;
        if($Path=~/\.so\.(.*)/) {
            $Ver = $1;
        }
        
        if($Ver ne "") {
            $Cmd .= " -lver \"".$Ver."\"";
        }
    }
    
    if(defined $SkipStd) {
        $Cmd .= " -skip-cxx";
    }
    
    if(defined $PublicHeadersPath) {
        $Cmd .= " -public-headers \"$PublicHeadersPath\"";
    }
    
    if(defined $IgnoreTagsPath) {
        $Cmd .= " -ignore-tags \"$IgnoreTagsPath\"";
    }
    
    if(defined $KernelExport) {
        $Cmd .= " -kernel-export";
    }
    
    if(defined $SymbolsListPath) {
        $Cmd .= " -symbols-list \"$SymbolsListPath\"";
    }
    
    system($Cmd." >>$TMP_DIR/dumper.log");
    
    if($?) {
        printMsg("ERROR", "failed to run \'$ABI_DUMPER\' (".($?>>8).")");
    }
    
    return $EXTRA{$VN}."/ABI.dump";
}

sub getToolVer($)
{
    my $T = $_[0];
    return `$T -dumpversion`;
}

sub getToolVerInfo($)
{
    my $T = $_[0];
    return `$T -version`;
}

sub scenario()
{
    if($Help)
    {
        helpMsg();
        exit(0);
    }
    if($ShowVersion)
    {
        printMsg("INFO", "ABI Viewer $TOOL_VERSION");
        printMsg("INFO", "Copyright (C) 2025 Andrey Ponomarenko's ABI Laboratory");
        printMsg("INFO", "License: GNU LGPL 2.1 <http://www.gnu.org/licenses/>");
        printMsg("INFO", "This program is free software: you can redistribute it and/or modify it.\n");
        printMsg("INFO", "Written by Andrey Ponomarenko.");
        exit(0);
    }
    if($DumpVersion)
    {
        printMsg("INFO", $TOOL_VERSION);
        exit(0);
    }

    # check ABI Dumper
    if(getToolVerInfo($ABI_DUMPER)!~/EE/) {
        exitStatus("Module_Error", "ABI Dumper EE is not installed");
    }
    
    if(my $Version = getToolVer($ABI_DUMPER))
    {
        if(cmpVersions($Version, $ABI_DUMPER_VERSION)<0) {
            exitStatus("Module_Error", "the version of ABI Dumper should be $ABI_DUMPER_VERSION or newer");
        }
    }
    else {
        exitStatus("Module_Error", "cannot find \'$ABI_DUMPER\'");
    }
    
    if(not $Output) {
        $Output = ".";
    }
    
    my $Obj_0 = $ARGV[0];
    
    if(not $Obj_0) {
        exitStatus("Error", "object path is not specified");
    }
    
    if(not -e $Obj_0) {
        exitStatus("Access_Error", "can't access \'$Obj_0\'");
    }
    
    if(-d $Obj_0) {
        $EXTRA{1} = $Obj_0;
    }
    elsif($OutExtraInfo) {
        $EXTRA{1} = $OutExtraInfo;
    }
    
    loadModule("Basic");
    loadModule("ABI_Model");
    
    if($Diff)
    {
        my $Obj_1 = $ARGV[1];
        
        if(not $Obj_1) {
            exitStatus("Error", "second object path is not specified");
        }
        
        if(not -e $Obj_1) {
            exitStatus("Access_Error", "can't access \'$Obj_1\'");
        }
        
        if(-d $Obj_1) {
            $EXTRA{2} = $Obj_1;
        }
        elsif($OutExtraInfo) {
            exitStatus("Error", "you can't specify both -extra-info and -diff options");
        }
        
        readABI($Obj_0, 1);
        readABI($Obj_1, 2);
    }
    else
    {
        readABI($Obj_0, 1);
    }
    
    viewABI();
    
    return 0;
}

scenario();
