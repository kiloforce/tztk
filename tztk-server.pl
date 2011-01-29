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

my $protocol_version = 8;
my $client_version = 99;
my $server_memory = "1024M";

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


my $tztk_dir = cat("tztk-dir") || "tztk";
my $cmddir = "$tztk_dir/allowed-commands";
my $snapshotdir = "$tztk_dir/snapshots";
my %msgcolor = (info => 36, warning => 33, error => 31, tztk => 32, chat => 35);
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
if (-d "$tztk_dir/waypoint-auth") {
  $wpauth{username} = cat('$tztk_dir/waypoint-auth/username');
  $wpauth{password} = cat('$tztk_dir/waypoint-auth/password');
  my $sessiondata = mcauth_startsession($wpauth{username}, $wpauth{password});

  if (!ref $sessiondata) {
    print color(tztk => "Failed to authenticate with waypoint-auth user $wpauth{username}: $sessiondata\n");
    %wpauth = ();
  } else {
    $wpauth{username} = $sessiondata->{username};
    $wpauth{session_id} = $sessiondata->{session_id};
  }
}

# connect to irc
my $irc;
if (-d "$tztk_dir/irc") {
  $irc = irc_connect({
    host    => cat("$tztk_dir/irc/host")    || "localhost",
    port    => cat("$tztk_dir/irc/port")    || 6667,
    nick    => cat("$tztk_dir/irc/nick")    || "minecraft",
    channel => cat("$tztk_dir/irc/channel") || "#minecraft",
  });
}

# start minecraft server
my $server_pid = 0;
$SIG{PIPE} = sub { print color(errror => "SIGPIPE (\$?=$?, k0=".(kill 0 => $server_pid).", \$!=$!)\n"); };
$server_pid = open2(\*MCOUT, \*MCIN, "java -Xmx$server_memory -Xms$server_memory -jar minecraft_server.jar nogui 2>&1");
print "Minecraft SMP Server launched with pid $server_pid\n";

my @players;
my $server_ready = 0;
my $want_list;
my $want_snapshot = 0;

my $sel = new IO::Select(\*MCOUT, \*STDIN);
$sel->add($irc->{socket}) if $irc;

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
        print "Minecraft server seems to have shut down.  Exiting...\n";
        exit;
      }
      my $mc = <MCOUT>;
      my ($msgprefix, $msgtype) = ("", "");
      # 2010-09-23 18:36:53 [INFO]
      ($msgprefix, $msgtype) = ($1, lc $2) if $mc =~ s/^([\d\-\s\:]*\[(\w+)\]\s*)//;
      $msgprefix = strftime('%F %T [MISC] ', localtime) unless length $msgprefix;
      $mc =~ s/\xc2\xa7[0-9a-f]//g; #remove color codes
      $msgtype = 'chat' if $msgtype eq 'info' && $mc =~ /^\<[\w\-]+\>\s+[^\-]/;
      print color($msgtype => $msgprefix.$mc);

      my ($cmd_user, $cmd_name, $cmd_args);

      # init messages
      # Done! For help, type "help" or "?"
      if ($mc =~ /^Done\!\s*For\s+help\,\s*type\b/) {
        $server_ready = 1;
        console_exec('list');
      # chat messages
      # <Username> Message text here
      } elsif ($mc =~ /^\<([\w\-]+)\>\s*(.+?)\s*$/) {
        my ($username, $msg) = ($1, $2);

        if ($msg =~ /^\-([\w\-]+)(?:\s+(.+?))?\s*$/) {
          ($cmd_user, $cmd_name, $cmd_args) = ($username, $1, $2);
        } else {
          irc_send($irc, "<$username> $msg") if $irc;
        }
      # whispers
      # 2011-01-08 21:24:10 [INFO] Topaz2078 whispers asdfasdf to nobody
      } elsif ($mc =~ /^([\w\-]+)\s+whispers\s+(.+?)\s+to\s+\-([\w\-]+)\s$/) {
        ($cmd_user, $cmd_name, $cmd_args) = ($1, $3, $2);
      # connection notices
      # Username [/1.2.3.4:5679] logged in with entity id 25
      } elsif ($mc =~ /^([\w\-]+)\s*\[\/([\d\.]+)\:\d+\]\s*logged\s+in\b/) {
        my ($username, $ip) = ($1, $2);

        if ($ip ne '127.0.0.1') {
          my ($whitelist_active, $whitelist_passed) = (0,0);
          if (-d "$tztk_dir/whitelisted-ips") {
            $whitelist_active = 1;
            $whitelist_passed = 1 if -e "$tztk_dir/whitelisted-ips/$ip";
          }
          if (-d "$tztk_dir/whitelisted-players") {
            $whitelist_active = 1;
            $whitelist_passed = 1 if -e "$tztk_dir/whitelisted-players/$username";
          }
          if ($whitelist_active && !$whitelist_passed) {
            console_exec(kick => $username);
            console_exec(say => "$username tried to join, but was not on any active whitelist");
            next;
          }
        }

        irc_send($irc, "$username has connected") if $irc && player_is_human($username);

        if (player_is_human($username) && -e "$tztk_dir/motd" && open(MOTD, "$tztk_dir/motd")) {
          console_exec(tell => $username => "Message of the day:");
          while (<MOTD>) {
            chomp;
            next unless /\S/;
            console_exec(tell => $username => $_);
          }
          close MOTD;
        }
      # connection lost notices
      # Username lost connection: Quitting
      } elsif ($mc =~ /^([\w\-]+)\s+lost\s+connection\:\s*(.+?)\s*$/) {
        my ($username, $reason) = ($1, $2);
        irc_send($irc, "$username has disconnected: $reason") if $irc && player_is_human($username);
        console_exec('list');
      # player counts
      # Player count: 0
      } elsif ($mc =~ /^Player\s+count\:\s*(\d+)\s*$/) {
        # players.txt upkeep
        console_exec('list');
      # userlist players.txt update
      # Connected players: Topaz2078
      } elsif ($mc =~ /^Connected\s+players\:\s*(.*?)\s*$/) {
        @players = grep {/^[\w\-]+$/ && player_is_human($_)} split(/[^\w\-]+/, $1);
        if (defined $want_list) {
          console_exec(tell => $want_list => "Connected players: " . join(', ', @players));
          $want_list = undef;
        }
        open(PLAYERS, ">$tztk_dir/players.txt");
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

      #($cmd_user, $cmd_name, $cmd_args) = ($1, $3, $2) if command_allowed($3);
      if (defined $cmd_name && command_allowed($cmd_name)) {
        if ($cmd_name eq 'create' && $cmd_args =~ /^(\d+)(?:\s*[x\*]\s*(\d+))?$/) {
          my ($id, $count) = ($1, $2||1);
          if (-d "$cmddir/create") {
            if (-d "$cmddir/create/whitelist" && !-e "$cmddir/create/whitelist/$id") {
              console_exec(tell => $cmd_user => "That material is not in the active creation whitelist.");
              next;
            }  elsif (-e "$cmddir/create/blacklist/$id") {
              console_exec(tell => $cmd_user => "That material is in the creation blacklist.");
              next;
            }
          }
          my $maxcreate = -e "$cmddir/create/max" ? cat("$cmddir/create/max") : 64;
          $count = $maxcreate if $count > $maxcreate;
          while ($count > 0) {
            my $amount = $count > 64 ? 64 : $count;
            $count -= $amount;
            console_exec(give => $cmd_user, $id, $amount);
          }
        } elsif ($cmd_name eq 'tp' && $cmd_args =~ /^([\w\-]+)$/) {
          my ($dest) = ($1);
          console_exec(tp => $cmd_user, $dest);
        } elsif ($cmd_name eq 'wp' && $cmd_args =~ /^([\w\-]+)$/) {
          my $waypoint = "wp-" . lc($1);
          if (!-e "$server_properties{level_name}/players/$waypoint.dat") {
            console_exec(tell => $cmd_user => "That waypoint does not exist!");
            next;
          }
          my $wp_user = $waypoint;
          if (%wpauth) {
            if (player_copy($waypoint, $wpauth{username})) {
              $wp_user = $wpauth{username};
            } else {
              console_exec(tell => $cmd_user => "Failed to adjust player data for authenticated user; check permissions of world files");
              next;
            }
          }
          my $wp_player = player_create($wp_user);
          if (!ref $wp_player) {
            console_exec(tell => $cmd_user => $wp_player);
            next;
          }
          console_exec(tp => $cmd_user, $wp_user);
          player_destroy($wp_player);
          player_copy($wpauth{username}, $waypoint) if %wpauth;
        } elsif ($cmd_name eq 'wp-set' && $cmd_args =~ /^([\w\-]+)$/) {
          my $waypoint = "wp-" . lc($1);
          my $wp_user = $waypoint;
          if (%wpauth) {
            if (!-e "$server_properties{level_name}/players/$waypoint.dat" || player_copy($waypoint, $wpauth{username})) {
              $wp_user = $wpauth{username};
            } else {
              console_exec(tell => $cmd_user => "Failed to adjust player data for authenticated user; check permissions of world files");
              next;
            }
          }
          my $wp_player = player_create($wp_user);
          if (!ref $wp_player) {
            console_exec(tell => $cmd_user => $wp_player);
            next;
          }
          console_exec(tp => $wp_user, $cmd_user);
          player_destroy($wp_player);
          player_copy($wpauth{username}, $waypoint) if %wpauth;
        } elsif ($cmd_name eq 'wp-list') {
          opendir(PLAYERS, "$server_properties{level_name}/players/");
          console_exec(tell => $cmd_user => join(", ", sort map {/^wp\-([\w\-]+)\.dat$/ ? $1 : ()} readdir(PLAYERS)));
          closedir(PLAYERS);
        } elsif ($cmd_name eq 'list') {
          console_exec('list');
          $want_list = $cmd_user;
        }
      }
    } elsif ($irc && $fh == $irc->{socket}) {
      if (!irc_read($irc)) {
        $sel->remove($irc->{socket});
        if ($irc = irc_connect($irc)) {
          $sel->add($irc->{socket});
        }
      }
    }
  } #foreach readable fh

  # snapshots
  my $snapshot_period;
  if ($snapshot_period = cat("$tztk_dir/snapshot-period")) {
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

  my $snapshot_max;
  if ($snapshot_max = cat("$tztk_dir/snapshot-max")) {
    if ($snapshot_max =~ /^\d+$/ && $snapshot_max >= 1) {
      opendir(SNAPSHOTS, $snapshotdir);
      my @snapshots = sort grep {/^snapshot\-[\d\-]+\.tgz$/} readdir(SNAPSHOTS);
      closedir(SNAPSHOTS);
      unlink "$snapshotdir/".shift(@snapshots) while @snapshots > $snapshot_max;
    }
  }

  console_exec(say => "Snapshot complete! (Saved $tar_count files.)");
}

sub player_create {
  my $username = lc $_[0];
  return "can't create fake player, server must set online-mode=false or provide a real user in $tztk_dir/waypoint-auth" unless %wpauth || $server_properties{online_mode} eq 'false';
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

sub command_allowed { -e "$tztk_dir/allowed-commands/$_[0]" }

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

  print color(tztk => "Connecting to IRC...\n");

  my $irc = irc_init($conf);

  if (!ref $irc) {
    print color(error => "$irc\n");
    return undef;
  }

  print $irc "JOIN $conf->{channel}\r\n";
  print color(tztk => "Connected to IRC successfully!\n");

  $conf->{socket} = $irc;
  return $conf;
}

sub irc_init {
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

  return $irc;
}

sub irc_read {
  my $irc = shift;

  my $socket = $irc->{socket};
  my $line = <$socket>;
  return 0 if !defined $line;

  if ($line =~ /^PING(.*)$/i) {
    print $socket "PONG$1\r\n";
  } elsif ($line =~ /^\:([^\!\@\s]+).*?\s+(.+?)\s+$/) {
    # messages
    my $nick = $1;
    my $cmd = $2;
    my @args;
    push @args, ($1||"").($2||"") while $cmd =~ s/^(?!\:)(\S+)\s|^\:(.+?)\s*$//;

    if (uc $args[0] eq 'PRIVMSG') {
      my ($channel, $msg) = @args[1,2];
      if ($msg =~ /^\s*\-list\s*$/) {
        irc_send($irc, "Connected players: " . join(', ', @players));
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
  my ($irc, $msg) = @_;
  print {$irc->{socket}} "PRIVMSG $irc->{channel} :$msg\r\n";
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
