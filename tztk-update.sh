#!/bin/sh

echo -n "Previous hash: "
md5sum minecraft_server.jar
wget -N -nv http://minecraft.net/download/minecraft_server.jar
echo -n "New hash:      "
md5sum minecraft_server.jar
