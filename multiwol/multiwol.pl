#!/usr/bin/perl -w
#
# MultiWOL - CGI script for power up computers remotely
#
# Copyright (c) 2010-2015, Alexander Moisseev <moiseev@mezonplus.ru>
# This software is released under the Simplified BSD License.
#

use strict;
use CGI qw(:standard);
use Socket;
use DB_File;
use Net::Wake;
use Net::Ping;
use Net::Domain qw(hostdomain);
use Locale::gettext;
use Net::ARP;
use open qw(:std :utf8);
use Config;
use IO::Socket;
use IO::Interface qw(:flags);
use POSIX qw( setlocale  LC_ALL );

use constant VERSION => 'MultiWOL 0.1.4';

##-----------------------------
## DEFAULT CONFIGURATION OPTIONS

# Paths (relative to multiwol.pl location)
our $dbFile       = 'multiwol.db';    # Database file.
our $localeDir    = 'locale';         # Locale directory.
our $staticDirURI = 'static';         # Static files directory URI.
our $dbFileURI    = $dbFile;          # Database file URI.

our @trustedUsers;

# Magic Packet parameters
our $defaultBroadcastAddr = '192.168.0.255';    # Default for new host.
our $broadcastPort        = 7;                  # UDP port.

# Host status probe options
our $timeout    = 2;     # Timeout beetween probes.
our $probeCount = 30;    # Stop after sending N unsuccessful probe packets.

our $defaultLanguage = '';

## End of CONFIGURATION OPTIONS
##-----------------------------

&ConfigDataRead('./multiwol.conf');

use constant REMOTE_USER => $ENV{REMOTE_USER};

my $msg="";
my $bClass="Warn";

# here's a stylesheet incorporated directly into the page
use constant STYLE => <<END;

body { font: 12px Arial, Helvetica, sans-serif, Verdana; }
table { margin: 0.5em 0 0 0.5em; border-collapse: collapse; }
th, td { padding: 0.25em 0.5em 0.25em 0.5em; border: 1px solid #ADB9CC; white-space: nowrap; }
caption { font-family: "Times New Roman", serif;
          text-align: left; padding: 0 0 1em;
          font-size: 18px;
}
hr { height: 1px; background-color: #999; border: 0;}
a:link, a:visited { color: #39f; text-decoration:none; }
a img { border: none; }
A.Button:link,A.Button:visited { float: right; width: 120px; padding: 3px;
                                 font-weight: bold; color: #fff; background-color: #39f;
                                 text-align: center;  text-decoration: none;

}
A.Button:hover,A.Button:active { background-color: #06c; }
B.Warn    { font-family: sans-serif; color: red; }
B.Confirm { font-family: sans-serif; color: green; }
#wrap { width:auto; min-width:500px; position: absolute; background:white; }
#footer { clear: both; display: block; padding: 3em; font-size: 80%; text-align: center; }
#footer a { padding: 0.5em; }

END

my %locale = (
               '' => '',
               ru => 'ru_RU.UTF-8',
             );

# Environment variable required for BSD, setlocale function for Linux
$ENV{LC_ALL} = setlocale( LC_ALL,
    url_param('lang')
    ? $locale{ url_param('lang') }
    : $locale{$defaultLanguage} );

# gettext defined here
my $d = Locale::gettext->domain("multiwol");
$d->dir($localeDir);
sub __ ($) { $d->get( shift ) }	# __ is alias for $d->get


use constant HOSTNAME_VALID_RE => qr/^(((([01]?\d{1,2}|2[0-4]\d|25[0-5])\.){3}([01]?\d{1,2}|2[0-4]\d|25[0-5])|(?=[-a-z0-9]{1,63}(\.|$|:))[a-z0-9]([-a-z0-9]*[a-z0-9])*((\.[a-z0-9]([-a-z0-9]*[a-z0-9])*)*\.[a-z]{2,63})?)(:\d{1,5})?)?$/i;

MAIN:
{
    if (defined(param("wakeup")) && defined(param("mac"))) {
        &send_mp(); exit;
    } elsif (defined(param("add"))) {
        &add_entry();
    } elsif (defined(param("delete"))) {
        &del_entry();
    } elsif (defined(param("getMAC"))) {
        &get_MAC();
    }
        &print_form();
}

sub ConfigDataRead {
    unless ( my $ret = do "@_" ) {
        warn "Couldn't execute @_: $@" if $@;
        warn "Couldn't open @_: $!"    if $!;
    }
}

sub send_mp { # send magic packets to selected hosts
    &print_header();
    print b(__"Wake-on-LAN packet has been sent to:"), br;
    my %entry=();
    my %port=();
    tie( %entry, 'DB_File', $dbFile, O_RDONLY )
      || die "Cannot open DBM " . $dbFile . ": $!";
    foreach my $mac(param('mac')) {
        if (my ($hostname_port, $broadcast_addr) = split(',', $entry{$mac})) { # DB entry may be deleted by another session
            my ($hostname, $port) = split(':', $hostname_port);
            printf( "%s %s:%u &nbsp;&nbsp; %s<br />",
                $mac, $broadcast_addr, $broadcastPort, $hostname_port );
            $mac =~ tr/-.//d; # remove dots and dashes
            # Send the wakeup packet
            Net::Wake::by_udp( $broadcast_addr, $mac, $broadcastPort );
            $port{$hostname} = $port if(defined $port);
        }
    }
    untie %entry;
    print p, b(__"Please wait until hosts goes online..."), br;

    while (my ($hostname,$port) = each(%port)) {
        unless (my $packed_address = inet_aton($hostname)) {
            delete $port{$hostname};
            print "$hostname &nbsp;&nbsp;", __"cannot resolve ip address", br;
        }
    }

    $|=1; # disable output buffering
    my $p = Net::Ping->new("tcp", 2); $p->service_check(1);
    my $count     = $probeCount;
    my $linebreak = 0;
    while ($count--) {
        while (my ($hostname,$port) = each(%port)) {
            $p->{port_num} = $port;
            my $ping = ($p->ping($hostname));
            if ($ping) {
            delete $port{$hostname}; $linebreak = 1;
            print br, "$hostname:$port", "&nbsp;&nbsp;", __"is now", " ", b({-class=>'Confirm'},__"on-line","!");
            }
        }
  last if ($count <= 0 || !%port);
        if ($linebreak) {print br; $linebreak = 0;}
        print ".";
        sleep($timeout);
    }

    $|=0; # enable output buffering
    undef($p);

    while (my ($hostname,$port) = each(%port)) {
        print br,  "$hostname &nbsp;&nbsp;", __"start-up", " ", b({-class=>'Warn'}, __"failed");
    }

    print p, button(-name=>'back',
                     -value=>__ 'Back',
                     -onClick=>'history.back()');
    &print_footer();
}

sub print_form {
    my $trusted_user = ( $#trustedUsers == 0 && $trustedUsers[0] eq '*' )
      || ( defined REMOTE_USER && grep $_ eq REMOTE_USER, @trustedUsers )
      ? 1
      : 0;

  # Print select form
    &print_header();
    print start_form, '<div>';

    if ( !defined REMOTE_USER and @trustedUsers ) {
        print b({-class=>'Warn'}, __ 'Authorization required.');
    } else {
        &build_table($trusted_user);

        print p,
            submit(-name=>'wakeup',
                   -value=>__ 'Wakeup'), " ";
        if ($trusted_user) { print submit(-name=>'delete', -value=>__ 'Delete'), " " };
        print reset,
            '</div>', end_form;
        &print_newmac_form() if ($trusted_user);
    }
    &print_footer();
}

sub print_newmac_form {
    print hr,
        start_form({-action=>url."?lang=".(defined(url_param('lang')) ? url_param('lang') : '')."#add"}), '<div>', a({-name=>"add"}), # set form action and add an ancor
        table( caption(__ 'Add new entry to list:'),
            TR([
                td(['', b(__ "Hostame:"), textfield(-name=>'new_hostname',

                                                    -title=>
'hostname:port

To test host availability MultiWOL will try to establish
TCP connection to specified port or 7 (echo) if omitted.

Examples:
    host
    host:22
    host.example.com:3389
',

                                                    -size=>40,
                                                    -maxlength=>420).' '.__ ('(hostname:port, default domain is').' '.i(hostdomain ()).')'
                ]),
                td(['*', b(__ "MAC:"), textfield(-name=>'new_mac',
                                                 -title=>
'Examples:
    AC:DE:48:01:02:03 (Unix)
    AC-DE-48-01-02-03 (Windows)
    ACDE.4801.0203 (Cisco)
    ACDE48010203
',

                                                 -size=>17,
                                                 -maxlength=>17).' '.__ ('(in any wellknown format)').' '.submit(-name=>'getMAC', -value=>__ 'get MAC')
                ]),
                td(['*', b(__ "Broadcast:"), textfield(-name=>'new_bc',
                                                       -default=>$defaultBroadcastAddr,
                                                       -size=>15,
                                                       -maxlength=>15)
                ]),
                td(['', b(__ "Owner:"), textfield(-name=>'new_owner',
                                                  -size=>15,
                                                  -maxlength=>15).' '.__ '(www username)'
                ]),
            ]),
        ), p,
        b({-class=>$bClass},$msg), p,
        a( { -class => 'Button', -href => $dbFileURI }, __ 'Backup database' ),
        submit( -name => 'add', -value => __ 'Add' ), " ", reset,
        '</div>', end_form;
}

sub build_table() {
    my %entry=();
    my @rows = th([__ 'Hostname',__ 'MAC address',__ 'Broadcast address',__ 'Owner']); #table header
    my $row_color = '#fff';

    my $p = Net::Ping->new("tcp", 0.05); $p->service_check(1);

    tie( %entry, 'DB_File', $dbFile, O_CREAT | O_RDWR, 0640 )
      || die "Cannot open DBM " . $dbFile . ": $!";
    while (my ($mac, $entry_val) = each %entry) {
        my ($hostname_port, $broadcast_addr, $owner) = split(',', $entry_val, 3);

        my $valid_owner = 0;
        if ( defined REMOTE_USER ) {
            foreach my $user ( split( ', ', $owner ) ) {
                if ( $user eq REMOTE_USER ) { $valid_owner = 1; last; }
            }
        }

        #display table row only to owners or trusted users
        next if ( !$_[0] && ( !$owner || !$valid_owner ) );

        my ($hostname, $port) = split(':', $hostname_port);
        $p->{port_num} = $port;
        my $ping = ($p->ping($hostname));

        if ($ping) { $row_color = '#cfc';
        } else { $row_color = '#fff';
        }
        push(@rows,td({-style =>"background-color:$row_color"},[checkbox(-name=>'mac',
                                                                         -value=>$mac,
                                                                         -label =>$hostname_port)]).td({-align=>'center'}, [
                                                                                                                                $mac,
                                                                                                                                defined($broadcast_addr)
                                                                                                                                ? $broadcast_addr
                                                                                                                                : $defaultBroadcastAddr,
                                                                                                                                $owner
                                                                                                                            ]
                                                                                                      )
        );
    }
    untie %entry;
    print table(TR(\@rows));
    print table(TR(td({-style =>"background-color:#cfc"}),td({-style =>"padding: 0 0 0 0.5em; border:0;"},__ "on-line")));
}

sub add_entry {
    my %entry=();
    if (param("new_hostname") !~ HOSTNAME_VALID_RE) {
        $msg = __"Malformed hostname";
    } elsif (param("new_bc") !~ /^(([01]?\d{1,2}|2[0-4]\d|25[0-5])\.){3}([01]?\d{1,2}|2[0-4]\d|25[0-5])$/) {
        $msg = __"Malformed broadcast address";
    } elsif (param("new_mac") !~ /^([\da-f]{2}[:\-]?[\da-f]{2}[:\-.]?){2}[\da-f]{2}[:\-]?[\da-f]{2}$/i) {
        $msg = __"Malformed MAC address";
    } else {
        my $new_owners = param("new_owner") =~ s/[ ,;]+/, /gr;
        tie( %entry, 'DB_File', $dbFile, O_CREAT | O_RDWR, 0640 )
          || die "Cannot open DBM " . $dbFile . ": $!";
        $entry{lc(param("new_mac"))} = (param("new_hostname").",".param("new_bc").",".$new_owners);
        untie %entry;
        $msg = __"Entry saved"; $bClass="Confirm";
    }
}

sub del_entry {
    my %entry=();
    tie( %entry, 'DB_File', $dbFile, O_RDWR )
      || die "Cannot open DBM " . $dbFile . ": $!";
    delete @entry{param('mac')};
    untie %entry;
}

sub get_MAC {
    my $mac = "unknown";
    if (param("new_hostname") !~ HOSTNAME_VALID_RE) {
        $msg = __"Malformed hostname";
    } else {
        my ($hostname, $port) = split(':', param("new_hostname"));
        if (my $packed_address = inet_aton($hostname)) {
            my $ipaddr = inet_ntoa($packed_address);
            my $p = Net::Ping->new("tcp", 3); #timeout lower than 3 is not enough for inactive PCs
            $p->port_number(defined($port) ? $port : 7);
            my $ping = ($p->ping($ipaddr));

            if ($Config{'osname'} =~ /bsd/i) {
                $mac = Net::ARP::arp_lookup("", $ipaddr);
            } else {
                $mac = &linux_arp_lookup($ipaddr);
            }

            param(-name=>'new_mac',-value=>$mac);
            undef($p);

        } else {
            $msg = __"cannot resolve ip address";
        }
    }
}

sub linux_arp_lookup($) {
    # Enumerate network interfaces and make ARP lookup for each one
    my $ipaddr = shift;
    my $mac = "unknown";
    my $s = IO::Socket::INET->new(Proto => 'udp');
    my @interfaces = $s->if_list;

    foreach (@interfaces) {
        my $flags = $s->if_flags($_);

        # Filter out up and running brodcast interfaces that have IP and valid MAC addresses.
        if ( $flags & IFF_BROADCAST &&
             $flags & IFF_UP &&
             $flags & IFF_RUNNING &&
             $s->if_addr($_) &&
             defined $s->if_hwaddr($_) &&
             ($s->if_hwaddr($_) !~ /^[-:.0]*$/)
           ) {
            $mac = Net::ARP::arp_lookup($_, $ipaddr);
      last if $mac !~ /^unknown/i;
        }
    }

    $mac = "unknown" if $mac =~ /^[-:.0]*$/;
    return $mac;
}

sub print_header {
    print header( -expires=>'now',
                  -charset => 'UTF-8'
          ),
        start_html( -title=>'MultiWOL - '.__"remote power-up of computers",
                    -head  => Link(
                        {
                            -rel  => 'icon',
                            -type => 'image/png',
                            -href => $staticDirURI . '/multiwolico.png'
                        }
                    ),
                    -style=>{-code=>STYLE},
                    -dtd=>'-//W3C//DTD XHTML 1.0 Strict//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd',
                    -lang => defined( url_param('lang') )
                      ? url_param('lang')
                      : $defaultLanguage,
                    -encoding=>'UTF-8'
        ),
        '<div id="wrap">',
        div({-style=>'float:right;'},
            a(
                { -href => 'http://multiwol.sourceforge.net' },
                img {
                    -src => $staticDirURI . '/multiwolico48.png',
                    -alt => 'MultiWOL'
                }
            )
        ),
        table (TR(td({-style =>"background-color:#cfc;font-size:24px;"}, "MultiWOL"), td(__"remote power-up of computers"))),
        p;
}

sub print_footer {
    print hr, address(a({href=>'http://multiwol.sourceforge.net'},VERSION)),
    div({id=>'footer'},
        a({ -href=>'http://validator.w3.org/check?uri=referer'}, img{
            -src=>'http://www.w3.org/Icons/valid-xhtml10-blue', -height=>'31', -width=>'88',
            -alt=>'Valid XHTML 1.0 Strict'}
        ),
        a({ -href=>'http://jigsaw.w3.org/css-validator/check/referer'}, img{
            -src=>'http://jigsaw.w3.org/css-validator/images/vcss-blue', -height=>'31', -width=>'88',
            -alt=>'Valid CSS!'}
        )
    ),
'</div>',
    end_html;
}

__END__

=head1 NAME

MultiWOL - CGI script for power up computers remotely

=head1 SYNOPSIS

B<multiwol.pl>[?I<options>...]

=head1 DESCRIPTION

MultiWOL is a perl CGI script for power up computers remotely.

=head2 Features

=over

=item *

Designed for I<multi>user environment. Each of the users can view and power up only certain predefined computers. 
Only trusted users have access to all list and may add and remove entries.

=item *

Auto get MAC through hostname or IP.

=item *

I<Multi>ple hosts can be selected to power up simultaneously.

=item *

Highlighting of on-line hosts.

=item *

Automatic check that remote host has or may has not awoken by trying to set up TCP connection to the predefined port.

=item *

All data are stored in DBM file, which can be easily downloaded through web UI for a backup.

=item *

I<Multi>-language support (English, Russian).

=back

=cut

=head1 OPTIONS

=over

=item B<lang=>I<lang> UI language (e.g. lang=ru for Russian). Default is English. $defaultLanguage overrides this default.

=back

=head1 FILES

=over

=item multiwol.db

DBM database.

=item multiwol.mo

is a translation file ./locale/I<ru>/LC_MESSAGES/

=back

=head1 REQUIREMENTS

Perl 5.014, IO::Interface, Locale::gettext, Net::ARP, Net::Wake, a web server with CGI capabilities

=head1 SEE ALSO

perl(1), Net::Wake(3)

=head1 AVAILABILITY

http://multiwol.sourceforge.net

=head1 INSTALLATION

=over

=item 1

Extract contents of archive in web server directory.

=item 2

Edit constants in multiwol.pl to match your configuration.

=back

=cut

=head1 AUTHOR

S<Alexander Moisseev E<lt>moiseev@mezonplus.ruE<gt>>

=head1 LICENSE and COPYRIGHT

 Copyright (c) 2010-2015, Alexander Moisseev
 All rights reserved.

 Redistribution and use in source and binary forms, with or without 
 modification, are permitted provided that the following conditions 
 are met:

 1. Redistributions of source code must retain the above copyright 
 notice, this list of conditions and the following disclaimer.

 2. Redistributions in binary form must reproduce the above copyright 
 notice, this list of conditions and the following disclaimer in the 
 documentation and/or other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS 
 IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED 
 TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A 
 PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT 
 HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, 
 SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT 
 LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, 
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY 
 THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT 
 (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE 
 OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

=cut
