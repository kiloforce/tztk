Topaz's Minecraft SMP Toolkit http://minecraft.topazstorm.com/


Topaz's Minecraft SMP Toolkit (or tztk) enhances the vanilla Minecraft
server by providing some useful scripts and in-game commands. Talk to
me about it at topaz.minecraft.toolkit@topazstorm.com.


= Scripts =

tztk-update.sh downloads the latest minecraft_server.jar from
minecraft.net and overwrites the local copy. Shut down the Minecraft
server before running this.

tztk-server.pl is like another person sitting at the Minecraft
console. When you run it, it runs the Minecraft server and acts as a
proxy between the server console and your terminal. However, when it
sees a chat message on the console that it recognizes as a command,
it takes action! See the commands list below for details. It will
only respond to commands which have corresponding files present in the
tztk/allowed-commands directory; for example, the -wp-set command will
only be recognized if the file tztk/allowed-commands/wp-set exists. It
will also maintain a tztk/players.txt file with a list of currently
connected players, much like the creative server did.


= In-game commands =

Entries in <angle brackets> are placeholders and should be replaced with
an actual value. Entries in [square brackets] are optional. Entries in
{curly|braces} are choices. For example, -create {<id>[x<count>]|<kit>}
implies you could actually type things like -create 278, -create 73x64,
or -create armor instead.

Commands may also be run secretly by prefixing them with /tell, as
in /tell -create 278 to create items secretly. Note that with /tell,
a command argument is still required (so Minecraft considers it a valid
/tell command); for example, to run -list secretly, one would need to
type /tell -list x instead.

-create {<id>[x<count>]|<kit>} creates the requested block or item for the
current player; up to 64 (by default) may be requested. Use the decimal
IDs found on minecraftwiki.net's data values page. Secretly, any non-digit
can be used between the ID and count, but don't tell anyone I said that.

To limit what can be created, change the allow file to a directory
(like tztk/allowed-commands/create/), and then put files with
the same names as decimal IDs in a subdirectory named either
whitelist (to only allow certain types) or blacklist (to only
disallow certain types). If the whitelist directory is present at
all, whitelists will be enforced. For example, create a file named
tztk/allowed-commands/create/whitelist/287 to only allow the creation
of string, or a file named tztk/allowed-commands/create/blacklist/46
(with no whitelist present) to disallow only the creation of TNT.

You can adjust the maximum amount (from the default of 64) by putting
the desired value in the tztk/allowed-commands/create/max file.

You can also define kits, lists of items which may be created by
just naming the kit instead of giving an ID. For example, you could
create a kit named armor which spawns the player a full set of diamond
armor when they type -create armor. To define a kit, create a file in
tztk/allowed-commands/create/kits/ and give it the name of the kit. Within
that file, put IDs, optionally followed by counts (just like -create
would take), one on each line. These definitions are limited by the same
rules as the standard -create command. For example, see the following
for a starter kit: tztk/allowed-commands/create/kits/starter.

Determining whether such a kit takes all the fun out of the game is left
as an exercise for the server admin.

-tp <player> teleports the user to the specified player.

-wp <name> teleports the user to the specified waypoint.

-wp-set <name> creates (or moves) the specified waypoint at (or to)
the user's location.

-wp-list lists all available waypoints.

-list lists all connected users.  Console commands

-snapshot may be invoked from the console to force a snapshot of the
world. This uses the same logic as the periodic snapshots, including
forcing a flush of all chunks and updating the latest symlink.


= Waypoints =

The waypoint system combines player-to-player teleportation with user
data persistence. A waypoint is really just a fake user which acts as a
teleport destination for other players. When one is created, a fake user
is logged in, teleported to the user, and logged back out. When one is
used, a fake user with the same name is logged in (where it logged out
upon creation, since user data is persisted), the user is teleported
to it, and it is logged back out. Waypoints are stored by the server
(that is, their user data is perissted) in the world directory under
players/wp-<name>.dat, which also happens to be the pattern the -wp-list
command searches for. Because users with arbitrary names need to be able
to log in, you'll need to set online-mode=false in your server.properties
file, which sadly also allows anyone to join without authentication
(but see the section on user whitelists below).

If you would prefer to keep online-mode set to true and you have a spare
Minecraft account you're not using, you can put its authentication
information in username and password files in the tztk/waypoint-auth
directory. If present, tztk-server.pl will use this account to
authenticate against minecraft.net and use that session ID to log in
to your server, swapping around waypoint data behind the scenes to keep
the locations distinct.


= User whitelists =

To restrict your server to only specific usernames or IPs, you can
create user whitelists. To do this, create a directory named either
tztk/whitelisted-ips or tztk/whitelisted-players. Once one of these
directories exists, the corresponding whitelist will be enforced,
even if it is empty. (Players on the same computer as the server
can always log in.) Then, place files named the same as the IPs or
usernames to be whitelisted in the appropriate directory; for example,
create tztk/whitelisted-players/Topaz2078 to let me play on your server,
or create tztk/whitelisted-ips/1.2.3.4 to allow anyone at 1.2.3.4 connect.


= Snapshots =

To create periodic snapshots, put the desired snapshot period (in
seconds) into a file named tztk/snapshot-period in the server's root
directory. (For example, to take a snapshot no more than once per day,
you could run echo 86400 > tztk/snapshot-period to create such a file.) As
tztk-server.pl runs, it will occasionally check this file and verify
that the most recent snapshot is within this period. Otherwise, it will
halt auto-saving, force a full save, tar/gzip the world directory, and
restart saving. The resulting .tgz files will appear in tztk/snapshots/,
wich the most recent snapshot pointed at by the tztk/snapshots/latest
symlink. To delete all but the latest few snapshots, put the desired
number of snapshots into a file named tztk/snapshot-max (this number
must be at least 1, of course).


= Minecraft<->IRC Chat bridge =

You can bridge your Minecraft server's chat with an IRC channel! To
do this, create a directory named tztk/irc/ and fill it with files
named host, port, nick, and channel filled with the parameters you'd
like the IRC client to use. If a file is not present, the defaults are
localhost:6667 as minecraft on #minecraft. In IRC, users can type -list
to see a list of currently connected Minecraft players.


= Message of the Day =

To provide users with an MOTD, create a file named tztk/motd in the
server's root directory. Each line of this file will be individually
whispered to players as they join the server.


= Requirements =

tztk expects a Unix-like environment (tested on Ubuntu, CentOS, and
Cygwin) and Perl. It expects java to be in your path. It expects to
be placed in the same directory as the vanilla server files (that
is, minecraft_server.jar and tztk-server.pl should be in the same
directory). It reads your server.properties file, which should also be
in the same directory, and assumes those values are correct and in use
(which they should be, since it loads them and starts the actual server
at the same time). For waypoints to work, you'll also need to either set
online-mode=false in your server.properties file, which sadly also allows
anyone to join without authentication, or set an unused Minecraft account
up for waypoint authentication. For snapshots to work, you'll also need
a tar binary installed and in your path which understands GNU Tar options.


= Download =

You can download a tar/gzip of tztk; it was last built on 2011-02-06 at
22:57 EST and is 6381 bytes. Its MD5 hash is 98907d7d, and its SHA256
hash is f43c3523. If you like, you can also clone the Git repository with
git clone http://minecraft.topazstorm.com/topaz-minecraft-smp-toolkit.git
to fork or work on a patch.


= Donate =

Although I am reluctant to do so, users of tztk have requested that
I accept donations. The intent was never for tztk to be a source of
profit, but rather simply a free, useful, open-source toolkit built
out of love for the game. However, if you'd like to show your support,
please feel free to donate to tztk. I really appreciate your kindness,
whether in emails, donations, or posts on the forum. Thank you!


= Todo =

- Prepay blocks into one-way "bank".
- Configurable command price based on banked blocks.
- Configurable crafting recipes based on banked blocks.
- Limit waypoints-per-user.
- Show the last online time of the last N offline players or a
  specific player based on players/*.dat modtime.
- Ability to jump directly to a coordinate by writing out a temporary
  waypoint file.


