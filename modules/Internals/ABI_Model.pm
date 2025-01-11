##################################################################
# Module for ABI Viewer
#
# Copyright (C) 2014-2015 Andrey Ponomarenko's ABI Laboratory
#
# Written by Andrey Ponomarenko
#
# PLATFORMS
# =========
#  Linux (x86, x86_64)
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
##################################################################
use strict;

my $BYTE = 8;

my %WORD = (
    "x86"=>4,
    "x86_64"=>8
);

sub classifyType($$)
{
    my ($Tid, $ABI) = @_;
    
    my $Arch = $ABI->{"Arch"};
    my $BTid = get_PureType($Tid, $ABI);
    my %Type = %{$ABI->{"TypeInfo"}{$BTid}};
    
    my %Classes = ();
    if($Type{"Name"} eq "void")
    {
        $Classes{0}{"Class"} = "VOID";
        return %Classes;
    }
    
    if($Arch eq "x86")
    { # System V ABI Intel386 Architecture Processor Supplement
        if(isFloat($Type{"Name"})) {
            $Classes{0}{"Class"} = "FLOAT";
        }
        elsif($Type{"Type"}=~/Intrinsic|Enum|Pointer|Ptr/) {
            $Classes{0}{"Class"} = "INTEGRAL";
        }
        else { # Struct, Class, Union
            $Classes{0}{"Class"} = "MEMORY";
        }
    }
    elsif($Arch eq "x86_64")
    { # System V ABI AMD64 Architecture Processor Supplement
        if($Type{"Type"}=~/Enum|Pointer|Ptr/
        or isScalar($Type{"Name"})
        or $Type{"Name"}=~/\A(_Bool|bool)\Z/) {
            $Classes{0}{"Class"} = "INTEGER";
        }
        elsif($Type{"Name"} eq "__int128"
        or $Type{"Name"} eq "unsigned __int128")
        {
            $Classes{0}{"Class"} = "INTEGER";
            $Classes{1}{"Class"} = "INTEGER";
        }
        elsif($Type{"Name"}=~/\A(float|double|_Decimal32|_Decimal64|__m64)\Z/) {
            $Classes{0}{"Class"} = "SSE";
        }
        elsif($Type{"Name"}=~/\A(__float128|_Decimal128|__m128)\Z/)
        {
            $Classes{0}{"Class"} = "SSE";
            $Classes{8}{"Class"} = "SSEUP";
        }
        elsif($Type{"Name"} eq "__m256")
        {
            $Classes{0}{"Class"} = "SSE";
            $Classes{24}{"Class"} = "SSEUP";
        }
        elsif($Type{"Name"} eq "long double")
        {
            $Classes{0}{"Class"} = "X87";
            $Classes{8}{"Class"} = "X87UP";
        }
        elsif($Type{"Name"}=~/\Acomplex (float|double)\Z/) {
            $Classes{0}{"Class"} = "MEMORY";
        }
        elsif($Type{"Name"} eq "complex long double") {
            $Classes{0}{"Class"} = "COMPLEX_X87";
        }
        elsif($Type{"Type"}=~/Struct|Class|Union|Array/)
        {
            if($Type{"Size"}>2*8) {
                $Classes{0}{"Class"} = "MEMORY";
            }
            else {
                %Classes = classifyAggregate($Tid, $ABI);
            }
        }
        else {
            $Classes{0}{"Class"} = "MEMORY";
        }
    }
    elsif($Arch eq "arm")
    {
        # TODO
    }
    
    return %Classes;
}

sub classifyAggregate($$)
{
    my ($Tid, $ABI) = @_;
    
    my $Arch = $ABI->{"Arch"};
    my $BTid = get_PureType($Tid, $ABI);
    my %Type = %{$ABI->{"TypeInfo"}{$BTid}};
    
    my $Word = $WORD{$Arch};
    
    my %MemGroup = ();
    my %MemOffset = ();
    
    if($Type{"Type"} eq "Array")
    {
        my $ETid = $ABI->{"TypeInfo"}{$BTid}{"BaseType"};
        my $EBTid = get_PureType($ETid, $ABI);
        my %BType = %{$ABI->{"TypeInfo"}{$EBTid}};
        
        my $Max = 0;
        if(my $BSize = $BType{"Size"}) {
            $Max = ($Type{"Size"}/$BSize) - 1;
        }
        
        foreach my $Pos (0 .. $Max)
        {
            $Type{"Memb"}{$Pos}{"type"} = $BType{"Tid"};
            $Type{"Memb"}{$Pos}{"name"} = "[$Pos]";
        }
    }
    
    if($Type{"Type"} eq "Union")
    {
        foreach my $Pos (keys(%{$Type{"Memb"}}))
        {
            $MemOffset{$Pos} = $Pos;
            $MemGroup{0}{$Pos} = 1;
        }
    }
    else
    { # Struct, Class
        foreach my $Pos (sort {int($a)<=>int($b)} keys(%{$Type{"Memb"}}))
        {
            my $Offset = $Type{"Memb"}{$Pos}{"offset"};
            $MemOffset{$Pos} = $Offset;
            
            my $GroupOffset = int($Offset/$Word)*$Word; # group by WORD
            $MemGroup{$GroupOffset}{$Pos} = 1;
        }
    }
    
    my %Classes = ();
    
    foreach my $GroupOffset (sort {int($a)<=>int($b)} (keys(%MemGroup)))
    {
        my %GroupClasses = ();
        foreach my $Pos (sort {int($a)<=>int($b)} (keys(%{$MemGroup{$GroupOffset}})))
        { # split the field into the classes
            my $MTid = $Type{"Memb"}{$Pos}{"type"};
            my $MName = $Type{"Memb"}{$Pos}{"name"};
            
            my %SubClasses = classifyType($MTid, $ABI);
            foreach my $Offset (sort {int($a)<=>int($b)} keys(%SubClasses))
            {
                if(defined $SubClasses{$Offset}{"Elems"})
                {
                    foreach (keys(%{$SubClasses{$Offset}{"Elems"}})) {
                        $SubClasses{$Offset}{"Elems"}{$_} = joinFields($MName, $SubClasses{$Offset}{"Elems"}{$_});
                    }
                }
                else {
                    $SubClasses{$Offset}{"Elems"}{0} = $MName;
                }
            }
            
            # add to the group
            foreach my $Offset (sort {int($a)<=>int($b)} keys(%SubClasses)) { 
                $GroupClasses{$MemOffset{$Pos}+$Offset} = $SubClasses{$Offset};
            }
        }
        
        # merge classes in the group
        my %MergeGroup = ();
        
        foreach my $Offset (sort {int($a)<=>int($b)} keys(%GroupClasses)) {
            $MergeGroup{int($Offset/$Word)}{$Offset} = $GroupClasses{$Offset};
        }
        
        foreach my $Offset (sort {int($a)<=>int($b)} keys(%MergeGroup))
        {
            while(mergeClasses($MergeGroup{$Offset}, $Arch)){};
        }
        
        %GroupClasses = ();
        foreach my $M_Offset (sort {int($a)<=>int($b)} keys(%MergeGroup))
        {
            foreach my $Offset (sort {int($a)<=>int($b)} keys(%{$MergeGroup{$M_Offset}}))
            {
                $GroupClasses{$Offset} = $MergeGroup{$M_Offset}{$Offset};
            }
        }
        
        # add to the result list of classes
        foreach my $Offset (sort {int($a)<=>int($b)} keys(%GroupClasses))
        {
            if($Type{"Type"} eq "Union")
            {
                foreach my $P (keys(%{$GroupClasses{$Offset}{"Elems"}}))
                {
                    if($P!=0) {
                        delete($GroupClasses{$Offset}{"Elems"}{$P});
                    }
                }
            }
            $Classes{$Offset} = $GroupClasses{$Offset};
        }
    }
    
    return %Classes;
}

sub mergeClasses($$)
{
    my ($PreClasses, $Arch) = @_;
    my @Offsets = sort {int($a)<=>int($b)} keys(%{$PreClasses});
    
    if($#Offsets==0) {
        return 0;
    }
    
    my %PostClasses = ();
    my $Num = 0;
    my $Merged = 0;
    while($Num<=$#Offsets-1)
    {
        my $Offset1 = $Offsets[$Num];
        my $Offset2 = $Offsets[$Num+1];
        
        my $C1 = $PreClasses->{$Offset1}{"Class"};
        my $C2 = $PreClasses->{$Offset2}{"Class"};
        
        my $ResClass = undef;
        
        if($Arch eq "x86_64")
        {
            if($C1 eq $C2) {
                $ResClass = $C1;
            }
            elsif($C1 eq "MEMORY"
            or $C2 eq "MEMORY") {
                $ResClass = "MEMORY";
            }
            elsif($C1 eq "INTEGER"
            or $C2 eq "INTEGER") {
                $ResClass = "INTEGER";
            }
            elsif($C1=~/X87/
            or $C2=~/X87/) {
                $ResClass = "MEMORY";
            }
            else {
                $ResClass = "SSE";
            }
        }
        
        if($ResClass)
        { # merged
            $PostClasses{$Offset1}{"Class"} = $ResClass;
            
            foreach (keys(%{$PreClasses->{$Offset1}{"Elems"}})) {
                $PostClasses{$Offset1}{"Elems"}{ $_ } = $PreClasses->{$Offset1}{"Elems"}{$_};
            }
            foreach (keys(%{$PreClasses->{$Offset2}{"Elems"}})) {
                $PostClasses{$Offset1}{"Elems"}{ $Offset2 + $_ - $Offset1 } = $PreClasses->{$Offset2}{"Elems"}{$_};
            }
            
            $Merged = 1;
        }
        else
        { # save unchanged
            $PostClasses{$Offset1} = $PreClasses->{$Offset1};
            $PostClasses{$Offset2} = $PreClasses->{$Offset2};
        }
        $Num += 2;
    }
    if($Num==$#Offsets) {
        $PostClasses{$Offsets[$Num]} = $PreClasses->{$Offsets[$Num]};
    }
    %{$PreClasses} = %PostClasses;
    
    return $Merged;
}

sub joinFields($$)
{
    my ($F1, $F2) = @_;
    if(substr($F2, 0, 1) eq "[")
    { # array elements
        return $F1.$F2;
    }
    else { # fields
        return $F1.".".$F2;
    }
}

sub isScalar($) {
    return ($_[0]=~/\A(unsigned |)(char|short|int|long|long long)\Z/);
}

sub isFloat($) {
    return ($_[0]=~/\A(float|double|long double)\Z/);
}

sub passRetval($$$)
{
    my ($Init, $Classes, $ABI) = @_;
    my $Arch = $ABI->{"Arch"};
    
    foreach my $Offset (sort {int($a)<=>int($b)} keys(%{$Classes}))
    {
        my $Elems = undef;
        if(defined $Classes->{$Offset}{"Elems"})
        {
            foreach (keys(%{$Classes->{$Offset}{"Elems"}})) {
                $Classes->{$Offset}{"Elems"}{$_} = joinFields(".retval", $Classes->{$Offset}{"Elems"}{$_});
            }
            $Elems = $Classes->{$Offset}{"Elems"};
        }
        else {
            $Elems = { 0 => ".retval" };
        }
        
        my $CName = $Classes->{$Offset}{"Class"};
        
        if($CName eq "VOID") {
            next;
        }
        
        if($Arch eq "x86_64")
        {
            my @INT = ("rax", "rdx");
            my @SSE = ("xmm0", "xmm1");
            
            if($CName eq "INTEGER")
            {
                if(my $R = getLastAvailable($Init, "f", @INT))
                {
                    useRegister($Init, $R, "f", $Elems);
                }
            }
            elsif($CName eq "SSE")
            {
                if(my $R = getLastAvailable($Init, "8l", @SSE))
                {
                    useRegister($Init, $R, "8l", $Elems);
                }
            }
            elsif($CName eq "SSEUP")
            {
                if(my $R = getLastUsed($Init, @SSE))
                {
                    useRegister($Init, $R, "8h", $Elems);
                }
            }
            elsif($CName eq "X87")
            {
                useRegister($Init, "st0", "8l", $Elems);
            }
            elsif($CName eq "X87UP")
            {
                useRegister($Init, "st0", "8h", $Elems);
            }
            elsif($CName eq "COMPLEX_X87")
            {
                useRegister($Init, "st0", "f", $Elems);
                useRegister($Init, "st1", "f", $Elems);
            }
            elsif($CName eq "MEMORY")
            {
                # If the type has class MEMORY, then the caller provides space for the return
                # value and passes the address of this storage in %rdi as if it were the first
                # argument to the function. In effect, this address becomes a “hidden” first
                # argument.
                
                useRegister($Init, "rdi", "f", {0 => ".result_ptr"});
            }
        }
    }
}

sub getCallConv_R($$)
{
    my ($ID, $ABI) = @_;
    my $Arch = $ABI->{"Arch"};
    my %Info = %{$ABI->{"SymbolInfo"}{$ID}};
    
    if($Info{"Constructor"}
    or $Info{"Destructor"}) {
        return {};
    }
    
    my $Rid = $ABI->{"SymbolInfo"}{$ID}{"Return"};
    my $RBid = get_PureType($Rid, $ABI);
    my %RBType = %{$ABI->{"TypeInfo"}{$RBid}};
    
    if($Arch eq "x86")
    {
        if($RBType{"Name"} eq "void") {
            return {".retval"=>""};
        }
        elsif($RBType{"Type"}=~/Struct|Union|Class/)
        {
            # If a function returns a structure or union, then the caller provides space for the
            # return value and places its address on the stack as argument word zero. In effect,
            # this address becomes a 'hidden' first argument.
            
            if(checkFastCall($ID, $ABI, $Arch))
            { # fastcall
                return {".result_ptr"=>"ecx"};
            }
            else {
                return {".result_ptr"=>"stack + 0"};
            }
        }
        elsif($RBType{"Type"}=~/Intrinsic|Pointer/)
        {
            # A function that returns an integral or pointer value places its result in register %eax.
            # A floating-point return value appears on the top of the Intel387 register stack. The
            # caller then must remove the value from the Intel387 stack, even if it doesn’t use the value.
            
            if($RBType{"Name"}=~/float|double/) {
                return {".retval"=>"st(0)"};
            }
            else {
                return {".retval"=>"eax"};
            }
        }
    }
    elsif($Arch eq "x86_64")
    {
        my %Classes = classifyType($Rid, $ABI);
        
        my $Init = { "UsedReg"=>() };
        passRetval($Init, \%Classes, $ABI);
        
        my %Conv = ();
        foreach my $Reg (sort keys(%{$Init->{"UsedReg"}}))
        {
            foreach my $Part (sort keys(%{$Init->{"UsedReg"}{$Reg}}))
            {
                foreach my $Offset (sort keys(%{$Init->{"UsedReg"}{$Reg}{$Part}}))
                {
                    my $Mem = $Init->{"UsedReg"}{$Reg}{$Part}{$Offset};
                    
                    if($Offset)
                    {
                        if($Part eq "8h") {
                            $Conv{$Mem} = $Reg." + ".(8 + $Offset);
                        }
                        else
                        { # f, 8l
                            $Conv{$Mem} = $Reg." + ".$Offset;
                        }
                    }
                    else
                    {
                        $Conv{$Mem} = $Reg;
                    }
                }
            }
        }
        
        #my @Keys = keys(%Conv);
        #if($#Keys==0)
        #{
        #    my $Key = $Keys[0];
        #    my $Val = $Conv{$Key};
        #    if($Key=~s/\A(\.retval)\..+/$1/)
        #    {
        #        $Conv{$Key} = $Val;
        #        delete($Conv{$Keys[0]});
        #    }
        #}
        
        return \%Conv;
    }
}

sub getCallConv_P($$$)
{
    my ($ID, $ABI, $Pos) = @_;
    
    my %Info = %{$ABI->{"SymbolInfo"}{$ID}};
    my %Conv = ();
    
    my $PName = $Info{"Param"}{$Pos}{"name"};
    my $PTid = $Info{"Param"}{$Pos}{"type"};
    
    $PTid = get_PureType($PTid, $ABI);
    my %TInfo = %{$ABI->{"TypeInfo"}{$PTid}};
    
    my %MemName = ();
    my %MemOffset = ();
    
    if(defined $TInfo{"Memb"})
    {
        foreach my $MP (keys(%{$TInfo{"Memb"}}))
        {
            $MemName{$MP} = $TInfo{"Memb"}{$MP}{"name"};
            $MemOffset{$MP} = $TInfo{"Memb"}{$MP}{"offset"};
        }
    }
    
    if(defined $Info{"Param"}{$Pos}{"offset"})
    {
        my $Offset = $Info{"Param"}{$Pos}{"offset"};
        
        if($Offset=~/\-\s*(\d+)/) {
            $Conv{$PName} = "stack - ".$1;
        }
        else {
            $Conv{$PName}="stack + ".$Offset;
        }
    }
    elsif(defined $Info{"Reg"})
    {
        my %Regs = ();
        foreach my $RP (sort keys(%{$Info{"Reg"}}))
        {
            if($RP eq $Pos) {
                $Regs{0} = $Info{"Reg"}{$RP};
            }
            elsif($RP=~/\A$Pos\+(\w+)/) {
                $Regs{$1} = $Info{"Reg"}{$RP};
            }
        }
        
        my @Rs = sort {int($b)<=>int($a)} keys(%Regs);
        
        if($#Rs==0)
        { # complete
            $Conv{$PName} = $Regs{$Rs[0]};
        }
        else
        { # partial
            my @Members = sort {int($b)<=>int($a)} keys(%MemName);
            my %Used = ();
            
            foreach my $Offset (@Rs)
            {
                foreach my $MP (@Members)
                {
                    if(not defined $Used{$MP}
                    and $MemOffset{$MP}>=$Offset)
                    {
                        $Conv{$PName.".".$MemName{$MP}} = $Regs{$Offset};
                        $Used{$MP} = 1;
                    }
                }
            }
        }
    }
    else
    { # missed info
        $Conv{$PName} = "";
    }
    
    return \%Conv;
}

sub checkFastCall($$$)
{ # TODO: check if fastcall
    my ($ID, $ABI, $Arch) = @_;
    
    my %Info = %{$ABI->{"SymbolInfo"}{$ID}};
    
    if($Arch eq "x86")
    {
        if(defined $Info{"Param"})
        {
            if(defined $Info{"Param"}{0}{"offset"}
            and $Info{"Param"}{0}{"offset"}==0)
            { # first parameter is passed via stack
                return 0;
            }
        }
        
        if(defined $Info{"Reg"})
        {
            if(defined $Info{"Reg"}{0}
            and $Info{"Reg"}{0} eq "edx")
            { # first parameter is passed via %edx
                return 1;
            }
        }
    }
    
    return 0;
}

sub useRegister($$$$)
{
    my ($Init, $R, $Offset, $Elems) = @_;
    if(defined $Init->{"UsedReg"}{$R})
    {
        if(defined $Init->{"UsedReg"}{$R}{$Offset})
        { # busy
            return 0;
        }
    }
    $Init->{"UsedReg"}{$R}{$Offset} = $Elems;
    return $R;
}

sub getLastAvailable(@)
{
    my $Init = shift(@_);
    my $Offset = shift(@_);
    foreach (@_)
    {
        if(not defined $Init->{"UsedReg"}{$_}) {
            return $_;
        }
        elsif(not defined $Init->{"UsedReg"}{$_}{$Offset}) {
            return $_;
        }
    }
    return undef;
}

sub getLastUsed(@)
{
    my $Init = shift(@_);
    my $Pos = 0;
    foreach (@_)
    {
        if(not defined $Init->{"UsedReg"}{$_})
        {
            if($Pos>0) {
                return @_[$Pos-1];
            }
            else {
                return @_[0];
            }
        }
        $Pos+=1;
    }
    return undef;
}

return 1;
