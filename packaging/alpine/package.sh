#!/bin/ash

BUILDUSER=$1

apk update
apk add alpine-sdk sudo
adduser $BUILDUSER -D
adduser $BUILDUSER abuild
if [ -d /stoney/keys ]; then
  cp -r /stoney/keys /home/$BUILDUSER/.abuild
else
  su $BUILDUSER -c "abuild-keygen -an"
fi
cp -r /stoney/pkg /home/$BUILDUSER/packages 2>/dev/null || :
chown -R $BUILDUSER:$BUILDUSER /home/$BUILDUSER/.abuild
cp /home/$BUILDUSER/.abuild/*.pub /etc/apk/keys
chown -R $BUILDUSER:$BUILDUSER /home/$BUILDUSER
chown -R $BUILDUSER:$BUILDUSER /stoney
chown -R $BUILDUSER:$BUILDUSER /builds
#su $BUILDUSER -c "cd /tmp
#tar --same-owner -xf /stoney/pkg/community/linux-chrultrabook-stoney/kernel.tar.gz || true"
#rm -f /stoney/pkg/community/linux-chrultrabook-stoney/kernel.tar.gz
#su $BUILDUSER -c "cd /tmp
#tar -Czf --no-overwrite-dir /stoney/pkg/community/linux-chrultrabook-stoney/kernel.tar.gz *"
#rm -rf /tmp/*
su $BUILDUSER -c "cd /stoney/pkg/community/linux-chrultrabook-stoney
abuild checksum"
su root -c "cd /stoney/pkg/community/linux-chrultrabook-stoney
abuild -rKFc"
cp -r /home/$BUILDUSER/packages/community/x86_64 /builds/pkg
cp -r /home/$BUILDUSER/.abuild /builds/keys
