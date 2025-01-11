##################################################################
# Module for ABI Monitor with basic functions
#
# Copyright (C) 2015 Andrey Ponomarenko's ABI Laboratory
#
# Written by Andrey Ponomarenko
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
use Fcntl;

sub isElf($)
{
    my $Path = $_[0];
    
    if(readBytes($Path) eq "7f454c46")
    { # ELF files
        return 1;
    }
    
    return 0;
}

sub readBytes($)
{
    sysopen(FILE, $_[0], O_RDONLY);
    sysread(FILE, my $Header, 4);
    close(FILE);
    
    my @Bytes = map { sprintf('%02x', ord($_)) } split (//, $Header);
    return join("", @Bytes);
}

sub readFile($)
{
    my $Path = $_[0];
    return "" if(not $Path or not -f $Path);
    open(FILE, $Path);
    local $/ = undef;
    my $Content = <FILE>;
    close(FILE);
    return $Content;
}

sub writeFile($$)
{
    my ($Path, $Content) = @_;
    return if(not $Path);
    if(my $Dir = dirname($Path)) {
        mkpath($Dir);
    }
    open(FILE, ">", $Path) || die ("can't open file \'$Path\': $!\n");
    print FILE $Content;
    close(FILE);
}

sub composeHTML_Head($$$$$)
{
    my ($Title, $Keywords, $Description, $TopDir, $Styles, $Scripts) = @_;
    
    if($Styles) {
        $Styles = "<link rel=\"stylesheet\" type=\"text/css\" href=\"".$TopDir."css/$Styles\" />";
    }
    
    if($Scripts) {
        $Scripts = "<script type=\"text/javascript\" src=\"".$TopDir."js/$Scripts\"></script>";
    }
    
    return "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\" \"http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd\">
    <html xmlns=\"http://www.w3.org/1999/xhtml\" xml:lang=\"en\" lang=\"en\">
    <head>
    <meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-8\" />
    <meta name=\"keywords\" content=\"$Keywords\" />
    <meta name=\"description\" content=\"$Description\" />
    $Styles
    $Scripts
    
    <title>
        $Title
    </title>
    
    </head>";
}

return 1;
