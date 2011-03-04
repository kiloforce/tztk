#!/usr/bin/perl -w
use strict;

# This is tztk-server.pl from Topaz's Minecraft SMP Toolkit!
# Notes and new versions can be found at http://minecraft.topazstorm.com/

use IO::Select;
use IPC::Open2;
use IO::Handle;
use IO::Socket;
use File::Copy;
use POSIX qw(strftime);

my $protocol_version = 9;
my $client_version = 11;
my $server_memory = "2024M";


#ken#
# function prototypes
sub readlastlogin;
sub writelastlogin;
sub showlastlogin;
sub clearplayersonline;
sub goplayersoffline;
sub playeroffline;
sub playeronline;


# client init
my %packet; %packet = (
  cs_long => sub { pack("N", unpack("L", pack("l", $_[0]))) },
  cs_short => sub { pack("n", unpack("S", pack("s", $_[0]))) },
  cs_string => sub { $packet{cs_short}(length $_[0]) . $_[0] },
  sc_short => sub { unpack("s", pack("S", unpack("n", $_[0]))) },
  cs_keepalive => sub { #()
    chr(0x00);
  },
  cs_login => sub { #(user, pass)
    chr(0x01) . $packet{cs_long}($protocol_version)  . $packet{cs_string}($_[0]) . $packet{cs_string}($_[1]) . ("\0" x 9);
  },
  cs_disconnect => sub { #(reason)
    chr(0xff) . $packet{cs_string}($_[0]);
  },
  cs_handshake => sub { #(user)
    chr(0x02) . $packet{cs_string}($_[0]);
  },
  sc_readnext => sub { #(handle)
    sysread($_[0], (my $type), 1);
    return defined($type=$packet{sc_typemap}{ord($type)}) ? {type=>$type, $packet{$type}($_[0])} : undef;
  },
  sc_typemap => {
    0x02 => 'sc_handshake',
    0xff => 'sc_disconnect',
  },
  sc_handshake => sub {
    sysread($_[0], (my $len), 2);
    $len = $packet{sc_short}($len);
    sysread($_[0], (my $server_id), $len);
    return (server_id => $server_id);
  },
  sc_disconnect => sub {
    sysread($_[0], (my $len), 2);
    $len = $packet{sc_short}($len);
    sysread($_[0], (my $message), $len);
    return (message => $message);
  },
);


my $cmddir = "tztk-allowed-commands";
my $snapshotdir = "tztk-snapshots";
my %msgcolor = (info => 36, warning => 33, error => 31, tztk => 32);
$|=1;

# load server properties
my %server_properties;
open(SERVERPROPERTIES, "server.properties") or die "failed to load server properties: $!";
while (<SERVERPROPERTIES>) {
  next if /^\s*\#/;
  next unless /^\s*([\w\-]+)\s*\=\s*(.*?)\s*$/;
  my ($k, $v) = (lc $1, $2);
  $k =~ s/\-/_/g;
  $server_properties{$k} = $v;
}
close SERVERPROPERTIES;
$server_properties{server_ip} ||= "localhost";
$server_properties{server_port} ||= 25565;
print color(tztk => "Minecraft server appears to be at $server_properties{server_ip}:$server_properties{server_port}\n");

# load waypoint authentication
my %wpauth;
if (-d "tztk-waypoint-auth") {
  $wpauth{username} = cat('tztk-waypoint-auth/username');
  $wpauth{password} = cat('tztk-waypoint-auth/password');
  my $sessiondata = mcauth_startsession($wpauth{username}, $wpauth{password});

  if (!ref $sessiondata) {
    print color(tztk => "Failed to authenticate with tztk-waypoint-auth user $wpauth{username}: $sessiondata\n");
    %wpauth = ();
  } else {
    $wpauth{username} = $sessiondata->{username};
    $wpauth{session_id} = $sessiondata->{session_id};
  }
}

# connect to irc
my ($irc, $irc_channel);
if (-d "tztk-irc") {
  print color(tztk => "Connecting to IRC...\n");
  $irc_channel = cat("tztk-irc/channel") || "#minecraft";
  $irc = irc_connect({
    host    => cat("tztk-irc/host")    || "localhost",
    port    => cat("tztk-irc/port")    || 6667,
    nick    => cat("tztk-irc/nick")    || "minecraft",
    channel => $irc_channel,
  });

  if (ref $irc) {
    print color(tztk => "Connected to IRC successfully!\n");
  } else {
    print color(error => "$irc\n");
    undef $irc;
  }
}

# start minecraft server
my $server_pid = 0;
$SIG{PIPE} = sub { print color(errror => "SIGPIPE (\$?=$?, k0=".(kill 0 => $server_pid).", \$!=$!)\n"); };
$server_pid = open2(\*MCOUT, \*MCIN, "java -Xmx$server_memory -Xms$server_memory -jar minecraft_server.jar nogui 2>&1");
print "Minecraft SMP Server launched with pid $server_pid\n";

my @players;
my $server_ready = 0;
my $want_list = 0;
my $want_snapshot = 0;

#ken#
clearplayersonline();

my $sel = new IO::Select(\*MCOUT, \*STDIN, $irc);
while (kill 0 => $server_pid) {
  foreach my $fh ($sel->can_read(60)) {
    if ($fh == \*STDIN) {
      my $stdin = <STDIN>;
      if (!defined $stdin) {
        # server is headless
        $sel->remove(\*STDIN);
        next;
      }
      if ($stdin =~ /^\-snapshot\s*$/) {
        snapshot_begin();
      } else {
        print MCIN $stdin;
      }
    } elsif ($fh == \*MCOUT) {
      if (eof(MCOUT)) {
        #ken#
        goplayersoffline( );
        print "MCOUT seems to be EOF.  Is the server dead?  Exiting...\n";
        exit;
      }
      my $mc = <MCOUT>;
      my ($msgprefix, $msgtype) = ("", "");
      # 2010-09-23 18:36:53 [INFO]
      ($msgprefix, $msgtype) = ($1, lc $2) if $mc =~ s/^([\d\-\s\:]*\[(\w+)\]\s*)//;
      $msgprefix = strftime('%F %T [MISC] ', localtime) unless length $msgprefix;
      print color($msgtype => $msgprefix.$mc);

      # init messages
      # Done! For help, type "help" or "?"
      if ($mc =~ /^Done\!\s*For\s+help\,\s*type\b/) {
        $server_ready = 1;
        console_exec('list');
      # chat messages
      # <Username> Message text here
      } elsif ($mc =~ /^\<([\w\-]+)\>\s*(.+?)\s*$/) {
        my ($username, $msg) = ($1, $2);

        irc_send($irc, $irc_channel, "<$username> $msg") if $irc;

        if (command_allowed("create") && $msg =~ /^\-create\s+(\d+)(?:\s*[x\*]\s*(\d+))?$/) {
          my ($id, $count) = ($1, $2||1);
          if (-d "$cmddir/create") {
            if (-d "$cmddir/create/whitelist" && !-e "$cmddir/create/whitelist/$id") {
              console_exec(say => "That material is not in the active creation whitelist.");
              next;
            }  elsif (-e "$cmddir/create/blacklist/$id") {
              console_exec(say => "That material is in the creation blacklist.");
              next;
            }
          }
          my $maxcreate = -e "$cmddir/create/max" ? cat("$cmddir/create/max") : 64;
          $count = $maxcreate if $count > $maxcreate;
          while ($count > 0) {
            my $amount = $count > 64 ? 64 : $count;
            $count -= $amount;
            console_exec(give => $username, $id, $amount);
          }
        } elsif (command_allowed("tp") && $msg =~ /^\-tp\s+([\w\-]+)$/) {
          my ($dest) = ($1);
          console_exec(tp => $username, $dest);
        } elsif (command_allowed("wp") && $msg =~ /^\-wp\s+([\w\-]+)$/) {
          my $waypoint = "wp-" . lc($1);
          if (!-e "$server_properties{level_name}/players/$waypoint.dat") {
            console_exec(say => "That waypoint does not exist!");
            next;
          }
          my $wp_user = $waypoint;
          if (%wpauth) {
            if (player_copy($waypoint, $wpauth{username})) {
              $wp_user = $wpauth{username};
            } else {
              console_exec(say => "Failed to adjust player data for authenticated user; check permissions of world files");
              next;
            }
          }
          my $wp_player = player_create($wp_user);
          if (!ref $wp_player) {
            console_exec(say => $wp_player);
            next;
          }
          console_exec(tp => $username, $wp_user);
          player_destroy($wp_player);
          player_copy($wpauth{username}, $waypoint) if %wpauth;
        } elsif (command_allowed("wp-set") && $msg =~ /^\-wp\-set\s+([\w\-]+)$/) {
          my $waypoint = "wp-" . lc($1);
          my $wp_user = $waypoint;
          if (%wpauth) {
            if (!-e "$server_properties{level_name}/players/$waypoint.dat" || player_copy($waypoint, $wpauth{username})) {
              $wp_user = $wpauth{username};
            } else {
              console_exec(say => "Failed to adjust player data for authenticated user; check permissions of world files");
              next;
            }
          }
          my $wp_player = player_create($wp_user);
          if (!ref $wp_player) {
            console_exec(say => $wp_player);
            next;
          }
          console_exec(tp => $wp_user, $username);
          player_destroy($wp_player);
          player_copy($wpauth{username}, $waypoint) if %wpauth;
        } elsif (command_allowed("wp-list") && $msg =~ /^\-wp\-list$/) {
          opendir(PLAYERS, "$server_properties{level_name}/players/");
          console_exec(say => join(", ", sort map {/^wp\-([\w\-]+)\.dat$/ ? $1 : ()} readdir(PLAYERS)));
          closedir(PLAYERS);
        } elsif (command_allowed("list") && $msg =~ /^\-list$/) {
          console_exec('list');
          $want_list = 1;
        #ken#
        } elsif ( command_allowed("spawn") && $msg =~ /^\-spawn$/) {
          my $waypoint = "wp-spawn";
          if (!-e "$server_properties{level_name}/players/$waypoint.dat") {
            console_exec(say => "That waypoint does not exist!");
            next;
          }
          my $wp_user = $waypoint;
          if (%wpauth) {
            if (player_copy($waypoint, $wpauth{username})) {
              $wp_user = $wpauth{username};
            } else {
              console_exec(say => "Failed to adjust player data for authenticated user; check permissions of world files");
              next;
            }
          }
          my $wp_player = player_create($wp_user);
          if (!ref $wp_player) {
            console_exec(say => $wp_player);
            next;
          }
          console_exec(tp => $username, $wp_user);
          player_destroy($wp_player);
          player_copy($wpauth{username}, $waypoint) if %wpauth;
        } elsif ( command_allowed("home") && $msg =~ /^\-home$/) {
          my $waypoint = "wp-" . lc( $username );
          if (!-e "$server_properties{level_name}/players/$waypoint.dat") {
            console_exec(say => "That waypoint does not exist!");
            next;
          }
          my $wp_user = $waypoint;
          if (%wpauth) {
            if (player_copy($waypoint, $wpauth{username})) {
              $wp_user = $wpauth{username};
            } else {
              console_exec(say => "Failed to adjust player data for authenticated user; check permissions of world files");
              next;
            }
          }
          my $wp_player = player_create($wp_user);
          if (!ref $wp_player) {
            console_exec(say => $wp_player);
            next;
          }
          console_exec(tp => $username, $wp_user);
          player_destroy($wp_player);
          player_copy($wpauth{username}, $waypoint) if %wpauth;
        } elsif (command_allowed("sethome") && $msg =~ /^\-sethome$/) {
          my $waypoint = "wp-" . lc( $username );
          my $wp_user = $waypoint;
          if (%wpauth) {
            if (!-e "$server_properties{level_name}/players/$waypoint.dat" || player_copy($waypoint, $wpauth{username})) {
              $wp_user = $wpauth{username};
            } else {
              console_exec(say => "Failed to adjust player data for authenticated user; check permissions of world files");
              next;
            }
          }
          my $wp_player = player_create($wp_user);
          if (!ref $wp_player) {
            console_exec(say => $wp_player);
            next;
          }
          console_exec(tp => $wp_user, $username);
          player_destroy($wp_player);
          player_copy($wpauth{username}, $waypoint) if %wpauth;
        } elsif ( command_allowed("last") && $msg =~ /^\-last$/ ) {
          showlastlogin();
        } elsif ( command_allowed("help") && $msg =~ /^\-help$/ ) {
          console_exec(say => ":: HELP:");
          console_exec(say => ": -help -- This help message");
          console_exec(say => ": -list -- List online users");
          console_exec(say => ": -last -- List users last login time and hours played");
          console_exec(say => ": -tp [user] -- Teleport to user");
          console_exec(say => ": -spawn -- Warp to spawn point");
          console_exec(say => ": -home -- Warp to user's 'sethome' location");
          console_exec(say => ": -sethome -- Set current location as user's home");
        }
      # connection notices
      # Username [/1.2.3.4:5679] logged in with entity id 25
      } elsif ($mc =~ /^([\w\-]+)\s*\[\/([\d\.]+)\:\d+\]\s*logged\s+in\b/) {
        my ($username, $ip) = ($1, $2);
        #ken#
        playeronline( $username );
        if ($ip ne '127.0.0.1') {
          my ($whitelist_active, $whitelist_passed) = (0,0);
          if (-d "tztk-whitelisted-ips") {
            $whitelist_active = 1;
            $whitelist_passed = 1 if -e "tztk-whitelisted-ips/$ip";
          }
          if (-d "tztk-whitelisted-players") {
            $whitelist_active = 1;
            $whitelist_passed = 1 if -e "tztk-whitelisted-players/$username";
          }
          if ($whitelist_active && !$whitelist_passed) {
            console_exec(kick => $username);
            console_exec(say => "$username tried to join, but was not on any active whitelist");
            next;
          }
        }
        irc_send($irc, $irc_channel, "$username has connected") if $irc && player_is_human($username);
        #ken#
        open MOTD, "motd";
        my $motd = <MOTD>;
        close MOTD;
        console_exec( tell => "$username " . $motd );
      # connection lost notices
      # Username lost connection: Quitting
      } elsif ($mc =~ /^([\w\-]+)\s+lost\s+connection\:\s*(.+?)\s*$/) {
        my ($username, $reason) = ($1, $2);
        #ken#
        playeroffline( $username );
        irc_send($irc, $irc_channel, "$username has disconnected: $reason") if $irc && player_is_human($username);
      # player counts
      # Player count: 0
      } elsif ($mc =~ /^Player\s+count\:\s*(\d+)\s*$/) {
        # players.txt upkeep
        console_exec('list');
      # userlist players.txt update
      # Connected players: Topaz2078
      } elsif ($mc =~ /^Connected\s+players\:\s*(.*?)\s*$/) {
        @players = grep {/^[\w\-]+$/ && player_is_human($_)} split(/[^\w\-]+/, $1);
        if ($want_list) {
          console_exec(say => "Connected players: " . join(', ', @players));
          $want_list = 0;
        }
        open(PLAYERS, ">tztk-players.txt");
        print PLAYERS map{"$_\n"} @players;
        close PLAYERS;
      # snapshot save-complete trigger
      # CONSOLE: Save complete.
      } elsif ($mc =~ /^CONSOLE\:\s*Save\s+complete\.\s*$/) {
        if ($want_snapshot) {
          $want_snapshot = 0;
          snapshot_finish();
        }
      }
    } elsif ($fh == $irc) {
      $sel->remove($irc) unless irc_read($irc);
    }
  } #foreach readable fh

  # snapshots
  if (-e "tztk-snapshot-period" && open(SNAPSHOTPERIOD, "tztk-snapshot-period")) {
    chomp(my $snapshot_period = <SNAPSHOTPERIOD>);
    close SNAPSHOTPERIOD;

    if ($snapshot_period =~ /^\d+$/) {
      mkdir $snapshotdir unless -d $snapshotdir;
      if (!-e "$snapshotdir/latest" || time - (stat("$snapshotdir/latest"))[9] >= $snapshot_period) {
        snapshot_begin();
      }
    }
  }
} continue {
  # in case of unexpected catastrophic i/o errors, yield to prevent spinlock
  select undef, undef, undef, .01;
}

print "Can no longer reach server at pid $server_pid; is it dead?  Exiting...\n";

sub color {
  my ($color, $message) = (lc $_[0], $_[1]);
  my $rv = "";
  $rv .= "\e[$msgcolor{$color}m" if exists $msgcolor{$color};
  $rv .= $message;
  $rv .= "\e[0m" if exists $msgcolor{$color};
  return $rv;
}

sub snapshot_begin {
  return unless $server_ready;
  console_exec('save-off');
  console_exec('save-all');
  $want_snapshot = 1;
}

sub snapshot_finish {
  console_exec(say => "Creating snapshot...");
  my $snapshot_name = strftime('snapshot-%Y-%m-%d-%H-%M-%S.tgz', localtime);
  my $tar_pid = open2(\*TAROUT, \*TARIN, "tar", "-czvhf", "$snapshotdir/$snapshot_name", '--', $server_properties{level_name});
  close TARIN;
  my $tar_count = 0;
  while (<TAROUT>) {
    $tar_count++;
  }
  waitpid $tar_pid, 0;
  close TAROUT;
  console_exec('save-on');
  unlink("$snapshotdir/latest");
  symlink("$snapshot_name", "$snapshotdir/latest");
  console_exec(say => "Snapshot complete! (Saved $tar_count files.)");
}

sub player_create {
  my $username = lc $_[0];
  return "can't create fake player, server must set online-mode=false or provide a real user in tztk-waypoint-auth" unless %wpauth || $server_properties{online_mode} eq 'false';
  return "invalid name" unless $username =~ /^[\w\-]+$/;

  my $player = IO::Socket::INET->new(
    Proto     => "tcp",
    PeerAddr  => $server_properties{server_ip},
    PeerPort  => $server_properties{server_port},
  ) or return "can't connect: $!";

  if (%wpauth) {
    print $player $packet{cs_handshake}($username);
    while (1) {
      my $packet = $packet{sc_readnext}($player);
      die "totally unexpected packet; did the protocol change?" unless defined $packet;
      return $packet->{message} if $packet->{type} eq 'sc_disconnect';
      if ($packet->{type} eq 'sc_handshake') {
        my $status = mcauth_joinserver($username, $wpauth{session_id}, $packet->{server_id});
        last if $status eq 'OK';
        return $status;
      }
    }
  }

  syswrite($player, $packet{cs_login}($username, ""));
  select undef, undef, undef, .2;
  syswrite($player, $packet{cs_keepalive}());
  return $player;
}

sub player_destroy {
  syswrite($_[0], $packet{cs_keepalive}());
  select undef, undef, undef, .8;
  syswrite($_[0], $packet{cs_disconnect}($_[0]||""));
  select undef, undef, undef, .8;
  close $_[0];
}

sub player_copy {
  my ($datafile, $username) = @_;

  my $user_dat = "$server_properties{level_name}/players/$username.dat";
  my $user_bkp = "$server_properties{level_name}/players/$username.bkp";
  my $data_dat = "$server_properties{level_name}/players/$datafile.dat";

  if (-e $user_dat) {
    if (-l $user_dat) {
      # remove the old link
      unlink $user_dat;
    } else {
      # original username exists, back up profile just in case
      return 0 unless rename $user_dat, $user_bkp;
    }
  }

  my $success = copy $data_dat, $user_dat;
}

sub player_is_human {
  return $_[0] !~ /^wp\-/ && (!%wpauth || $_[0] ne $wpauth{username});
}

sub mcauth_startsession {
  my @gvd = split(/\:/, http('www.minecraft.net', '/game/getversion.jsp', 'user='.urlenc($_[0]).'&password='.urlenc($_[1]).'&version='.urlenc($client_version)));
  return join(':', @gvd) if @gvd < 4;
  return {version=>$gvd[0], download_ticket=>$gvd[1], username=>$gvd[2], session_id=>$gvd[3]};
}

sub mcauth_joinserver {
  return http('www.minecraft.net', '/game/joinserver.jsp?user='.urlenc($_[0]).'&sessionId='.urlenc($_[1]).'&serverId='.urlenc($_[2]));
}

sub command_allowed { -e "tztk-allowed-commands/$_[0]" }

sub console_exec {
  print MCIN join(" ", @_) . "\n";
}

sub cat {
  open(FILE, $_[0]) or return undef;
  chomp(my $line = <FILE>);
  close FILE;
  return $line;
}

sub irc_connect {
  my $conf = shift;
  my $irc = new IO::Socket::INET(
    PeerAddr => $conf->{host},
    PeerPort => $conf->{port},
    Proto    => 'tcp'
  ) or return "couldn't connect to irc server: $!";

  print $irc "NICK $conf->{nick}\r\n";
  print $irc "USER $conf->{nick} 8 * :Minecraft-IRC proxy bot\r\n";

  while (<$irc>) {
    if (/^PING(.*)$/i) {
      print $irc "PONG$1\r\n";
    } elsif (/^\:[\w\-\.]+\s+004\b/) {
      last;
    } elsif (/^\:[w\-\.]+\s+433\b/) {
      return "couldn't connect to irc server: nick is in use";
    }
  }

  print $irc "JOIN $conf->{channel}\r\n";

  return $irc;
}

sub irc_read {
  my $irc = shift;

  my $line = <$irc>;
  return 0 if !defined $line;

  if ($line =~ /^PING(.*)$/i) {
    print $irc "PONG$1\r\n";
  } elsif ($line =~ /^\:([^\!\@\s]+).*?\s+(.+?)\s+$/) {
    # messages
    my $nick = $1;
    my $cmd = $2;
    my @args;
    push @args, ($1||"").($2||"") while $cmd =~ s/^(?!\:)(\S+)\s|^\:(.+?)\s*$//;

    if (uc $args[0] eq 'PRIVMSG') {
      my ($channel, $msg) = @args[1,2];
      if ($msg =~ /^\s*\-list\s*$/) {
        irc_send($irc, $channel, "Connected players: " . join(', ', @players));
      } else {
        console_exec(say => "<$nick> $args[2]");
      }
    } elsif (uc $args[0] eq 'JOIN') {
      console_exec(say => "$nick has joined the IRC channel");
    } elsif (uc $args[0] eq 'PART') {
      console_exec(say => "$nick has left the IRC channel");
    }
  }

  return 1;
}

sub irc_send {
  my ($irc, $channel, $msg) = @_;
  print $irc "PRIVMSG $channel :$msg\r\n";
}

sub urlenc {
  local $_ = $_[0];
  s/([^a-zA-Z0-9\ ])/sprintf("%%%02X",ord($1))/ge;
  s/\ /\+/g;
  return $_;
}

sub http {
  my ($host, $path, $post) = @_;

  my $http = IO::Socket::INET->new(
    Proto     => "tcp",
    PeerAddr  => $host,
    PeerPort  => 80,
  ) or die "can't connect to $host for http: $!";

  print $http +(defined $post ? "POST" : "GET")." $path HTTP/1.0\r\nHost: $host\r\n";
  if (defined $post) {
    print $http "Content-Length: ".length($post)."\r\nContent-Type: application/x-www-form-urlencoded\r\n\r\n$post";
  } else {
    print $http "\r\n";
  }

  while (<$http> =~ /\S/) {}
  return join("\n", <$http>);
}



#
# MODIFICATIONS BY KENNETH #
#


sub readlastlogin {
  my %users = ();
  open FILE, "lastlog.txt";
  foreach my $line ( <FILE> ) {
    my %userdata = ();
    my ( $user, $userlastlogin, $usertotaltime, $useronline ) = split( ',' , $line );
    chomp $useronline;
    $users{ $user }{ last } = int( $userlastlogin );
    $users{ $user }{ total } = int( $usertotaltime );
    $users{ $user }{ online } = int( $useronline );
    # print " :DEBUG> " . $user . " " . $users{ $user }{ last } . " " . $users{ $user }{ total } . " " . $users{ $user }{ online } . "\n";
  }
  close FILE;
  return %users;
}

sub writelastlogin {
  my ( %users ) = @_;
  open FILE, ">", "lastlog.txt";
  foreach my $user ( sort { $users{ $a }{ last } cmp $users{ $b }{ last } } keys %users ) {
    if ( $user =~ /^wp-/ ) { next; }
    #print " :DEBUG> " . $user . " " . $users{ $user }{ last } . " " . $users{ $user }{ total } . " " . $users{ $user }{ online } . "\n";
    print FILE $user . "," . $users{ $user }{ last } . "," . $users{ $user }{ total } . "," . $users{ $user }{ online } . "\n";
  }
  close FILE;
}

sub showlastlogin {
  # TODO: only list last 18 users or less (20 lines)

  console_exec( say => ":: Last Login:" );

  my $now = time( );

  my ( %users ) = readlastlogin( );

  # sort by login time:
  foreach my $user ( sort { $users{ $a }{ last } cmp $users{ $b }{ last } } keys %users ) {
    my $userlastlogin = $users{ $user }{ last };
    my $usertotaltime = $users{ $user }{ total };
    my $useronline = $users{ $user }{ online };
    my $userhours;

    #if ( $usertime == 0 ) {
    #  next;
    #}
    my $difftime = $now - $userlastlogin;
    my $timename;
    my $timecount;

    # user hours played
    if ( $useronline ) {
      $userhours = int( ( $usertotaltime + $now - $userlastlogin ) / 60 / 60 );
    } else {
      $userhours = int( $usertotaltime / 60 / 60 );
    }

    # user last online
    if ( $useronline ) {
      $timecount = "";
      $timename = " ONLINE";
    } elsif ( $difftime >= 172800 ) {
      # > 2 days
      $timecount = int( $difftime / 60 / 60 / 24 );
      $timename = " day(s) ago";
    } elsif ( $difftime >= 3600 and $difftime < 172800) {
      $timecount = int( $difftime / 60 / 60 );
      $timename = " hour(s) ago";
    } elsif ( $difftime > 0 and $difftime < 3600 ) {
      $timecount = int( $difftime / 60 );
      $timename = " minutes ago";
    }

    console_exec( say => ":: " . $user . " - " . $timecount . $timename . " (" . $userhours . " hours)");
  }

  # handle online users last
  #foreach my $user ( keys %users ) {
  #  my $usertime = $users{ $user } ;
  #  if ( $usertime == 0 ) {
  #    console_exec( say => ":: " . $user . " - ONLINE");
  #  }
  #}
}

sub clearplayersonline {
  my ( %users ) = readlastlogin( );
  foreach my $user ( sort { $users{ $a }{ last } cmp $users{ $b }{ last } } keys %users ) {
    #print " :DEBUG> " . $user . " " . $users{ $user }{ last } . " " . $users{ $user }{ total } . " " . $users{ $user }{ online } . "\n";
    if ( $users{ $user }{ online } == 1 ) {
      $users{ $user }{ online } = 0;
      #print " :ADEBUG> " . $user . " " . $users{ $user }{ last } . " " . $users{ $user }{ total } . " " . $users{ $user }{ online } . "\n";
    }
  }
  writelastlogin( %users );
}

sub goplayersoffline {
  my ( %users ) = readlastlogin( );
  my $now = time( );
  foreach my $user ( sort { $users{ $a }{ last } cmp $users{ $b }{ last } } keys %users ) {
    if ( $users{ $user }{ online } == 1 ) {
      $users{ $user }{ online } = 0;
      my $userlastlogin = $users{ $user }{ last };
      $users{ $user }{ last } = $now;
      my $usertotaltime = $users{ $user }{ total };
      $users{ $user }{ total } = $usertotaltime + ( $now - $userlastlogin );
    }
  }
  writelastlogin( %users );
}

sub playeroffline {
  my ( $username ) = @_;
  if ( $username =~ /^wp-/ ) { return; }

  my $now = time();

  if ( ! $username =~ /[A-Za-z0-9]/ ) { return; }
  my ( %users ) = readlastlogin( );
  my $userlastlogin = $users{ $username }{ last };
  $users{ $username }{ last } = $now;
  $users{ $username }{ total } = $users{ $username }{ total } + $now - $userlastlogin;
  $users{ $username }{ online } = 0;

  print $username . " offline\n";
  writelastlogin( %users );
}

sub playeronline {
  my ( $username ) = @_;
  if ( $username =~ /^wp-/ ) { return; }

  my $now = time( );

  if ( ! $username =~ /[A-Za-z0-9]/ ) { return; }
  my ( %users ) = readlastlogin( );
  my $userlastlogin = $users{ $username }{ last };
  $users{ $username }{ last } = $now;
  if( ! $users{ $username }{ total } ) {
    $users{ $username }{ total } = 0;
  }
  $users{ $username }{ online } = 1;

  print $username . " online\n";
  writelastlogin( %users );
}

