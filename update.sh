#!/bin/sh

echo -n "Minecraft Server: "
A=`cat minecraft_server.jar | md5sum`
wget -q http://minecraft.net/download/minecraft_server.jar -O minecraft_server.jar.new
B=`cat minecraft_server.jar.new | md5sum`
S=`cat minecraft_server.jar.new | wc -c`
if [ $S -lt 1000 ] ; then
  echo "ERROR DOWNLOADING NEW MINECRAFT VERSION!"
  exit 1
fi
if [ "$A" != "$B" ] ; then
  echo "NEW VERSION FOUND!"
  mv minecraft_server.jar.new minecraft_server.jar
else
  echo "No change."
  rm -f minecraft_server.jar.new
fi

echo -n "Topaz Toolkit: "
A=`cat topaz-minecraft-smp-toolkit.tgz | md5sum`
wget -q http://minecraft.topazstorm.com/topaz-minecraft-smp-toolkit.tgz -O topaz-minecraft-smp-toolkit.tgz.new
B=`cat topaz-minecraft-smp-toolkit.tgz.new | md5sum`
S=`cat topaz-minecraft-smp-toolkit.tgz.new | wc -c`
if [ $S -lt 1000 ] ; then
  echo "ERROR DOWNLOADING NEW TZTK VERSION!"
  exit 1
fi
if [ "$A" != "$B" ] ; then
  echo "NEW VERSION FOUND!"
  mv topaz-minecraft-smp-toolkit.tgz.new topaz-minecraft-smp-toolkit.tgz
else
  echo "No change."
  rm -f topaz-minecraft-smp-toolkit.tgz.new
fi

