#!/bin/bash
##########################################################
# SAUVEGARDE SYSTEME
# 
# Authors: 
#   Sebastien DERRE <Sebastien.Derre@banque-france.fr>
#   Hugo JACOB <Hugo.Jacob@banque-france.fr>
#   Frederic DIENOT <Frederic.Dienot.external@banque-france.fr>
#   Raphael BORDET <Raphael.Bordet.external@banque-france.fr>
#
# MAJ : 02/03/2015
#
# Utilisation de FSARCHIVER
# Script uniquement modifiable avec l'accord de INFRA UNIX
# OS : RHEL5 / RHEL6
###########################################################

# Pour des raisons de securite
umask 0077

# Pour sortir proprement
clean_exit() {
  RETURN=${1:-3}
  find /var/log -name "backup_*.out" -mtime +90 -exec rm {} \;
  chown ftpperf:ftpusers /var/log/backup*out
  chmod 644 /var/log/backup*out
  cp /var/log/backup*out /mnt/nfsbackup/$HOST 2>/dev/null
  echo -e "\033[40;1;32m=== DEMONTAGE DU PARTAGE NFS ===\033[0m\n"
  umount -f /mnt/nfsbackup 2>/dev/null
  exit $RETURN
}

trap clean_exit SIGHUP SIGINT SIGTERM

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/seos/bin:/root/bin
export PATH

# Verif root
if [ $EUID -ne 0 ]
  then
  echo "Ce script doit etre lance en tant que root" 1>&2
  exit 1
fi

HOST=$(hostname -s)
case ${HOST:2:2} in
  dv|re) NFS=development;;
  in)    NFS=integration;;
  pr|ho) NFS=production;;
  *)     NFS=test;;
esac

DATE=$(date +%Y_%m_%d-%H:%M)
DIRLOG=/var/log
export DIRLOG
LOGFILE=backup_${HOST}_$(date +\%Y_\%m_\%d).out
export LOGFILE
IS_RHEL_5=$(cat /etc/redhat-release | { grep -c 'release 5' ||true; })
IS_RHEL_6=$(cat /etc/redhat-release | { grep -c 'release 6' ||true; })
if [ $IS_RHEL_5 = 1 ]
  then
  RHEL_VERSION=el5
elif [ $IS_RHEL_6 = 1 ]
  then
  RHEL_VERSION=el6
else
  RHEL_VERSION=UNKNOWN
fi

# Releve de la config Hardware du serveur physique
if [ -x /root/hardware.sh -a -x /sbin/hpasmcli -a -x /sbin/hplog -a -x /opt/compaq/hpacucli/bld/hpacucli ]
  then
  /root/hardware.sh show
elif [ -x /root/hardware.sh -a -x /opt/dell/srvadmin/bin/omreport ]
  then
  /root/hardware.sh show
fi

{
START=$(date +%s)
exec 2>&1
CORE=$(grep -c 'processor' /proc/cpuinfo)
export CORE

# fsarchiver ne supporte que jusqu'a 32 jobs simulatnes. On limite donc CORE a 32.
if [ $CORE -gt 32 ]
  then
  export CORE=32
fi

echo -e "\033[40;1;32m=== SAUVEGARDE SYSTEME rh$RHEL_VERSION ===\033[0m"

echo -e "\033[43;6;30m=== Log de l'execution du script $DIRLOG/$LOGFILE ===\033[0m"
echo "=> Debut ${DATE}"

echo -e "\033[40;1;32m=== SUPPRESSION DE SNAPSHOT EVENTUELLEMENT EXISTANT ===\033[0m"
if lvscan | grep snap | egrep 'slash|usr|opt|var|seos|home'
  then
  case $RHEL_VERSION in
    el5) lvremove -f /dev/$(grep usr /proc/mounts | head -n1 | cut -d/ -f3)/{slash,usr,opt,var,seos,home}*snap ;;
    el6) lvremove -f $(grep usr /proc/mounts | head -n1 | cut -d- -f1)-{slash,usr,opt,var,seos,home}*snap ;;
    *)
      echo "Erreur : OS Inconnu"
      clean_exit ;;
   esac
else
   echo "=> Aucun snapshot systeme detecte"
fi

echo -e "\033[40;1;32m=== SUPPRESSION de backupLV - liberation des 6G reserves pour les snapshots ===\033[0m"
lvscan | grep -q backupLV || echo "backupLV n'existe pas"
case $RHEL_VERSION in
  el5) lvscan | grep -q backupLV && lvremove -f /dev/$(grep usr /proc/mounts | head -n1 | cut -d/ -f3)/backupLV ;;
  el6) lvscan | grep -q backupLV && lvremove -f $(grep usr /proc/mounts | head -n1 | cut -d- -f1)/backupLV ;;
  *)
    echo "Erreur : OS Inconnu"
    clean_exit ;;
esac

echo -e "\033[40;1;32m=== MONTAGE DU PARTAGE NFS POUR DEPOT DE LA SAUVEGARDE ===\033[0m"

if [ -d "/mnt/nfsbackup" ]
  then
  echo "=> Le repertoire /mnt/nfsbackup existe "
else
  echo "=> Creation du repertoire /mnt/nfsbackup"
  mkdir -p /mnt/nfsbackup
fi

if grep -q "nfsbackup nfs" /etc/mtab
  then
  echo "=> Partage NFS deja monte"
else
  echo "=> Montage du partage NFS"
  mount -t nfs4 r-isis.unix.intra.bdf.local:/home/svsys/appli/bdf/nfsbackup /mnt/nfsbackup
  if [ $? -ne 0 ]
    then
    echo "Erreur : Montage NFS"
    clean_exit
  fi
fi

if [ -d "/mnt/nfsbackup/$HOST" ]
  then
  echo "=> Le repertoire /mnt/nfsbackup/$HOST existe"
else
  echo "=> Creation du repertoire qui va accueillir la sauvegarde du serveur"
  mkdir /mnt/nfsbackup/$HOST
fi

if [ `df -Pk /mnt/nfsbackup | tail -1 | awk '{print $4}'` -lt "10485760" ]
  then
  echo "Erreur : Place libre insuffisante sur le partage NFS"
  clean_exit
fi

case $RHEL_VERSION in
  el5)
    if [ ! -s /usr/local/sbin/fsarchiver ] && [ ! -s /usr/sbin/fsarchiver ]
      then
      echo "=> fsarchiver introuvable, recuperation du binaire"
      cp /mnt/nfsbackup/fsarchiver-el5/fsarchiver /usr/local/sbin/
      chmod +x /usr/local/sbin/fsarchiver
    else
      echo "=> fsarchiver est present"
    fi ;;
  el6)
    if [ ! -s /usr/sbin/fsarchiver ]
      then
      yum -y install fsarchiver-0.6.15-1.el6.x86_64.rpm
    fi ;;
  *)
    echo "Erreur : OS Inconnu"
    clean_exit ;;
esac

cd /mnt/nfsbackup/$HOST

case $RHEL_VERSION in
  el5) lvdisplay | egrep -i 'slashlv|usrlv|optlv|varlv|seoslv|homelv' | awk '{ print $3 }' | sort > lvm.out ;;
  el6) lvdisplay | grep -i "LV Path" | egrep -i 'slashlv|usrlv|optlv|varlv|seoslv|homelv' | awk '{ print $3 }' | sort > lvm.out ;;
  *)
    echo "Erreur : OS Inconnu"
    clean_exit ;;
esac

IFS=$'\n'
sync

echo -e "\033[40;1;32m=> Sauvegarde de la partition /boot sous isis:/mnt/nfsbackup/$HOST/boot.fsa\033[0m"
if [ $(mount |grep -c boot) = 0 ]
  then
  echo "Pas de partition /boot separe"
else
  BOOT=`mount | grep boot | awk '{print $1}'`
  mount -o remount,ro $BOOT
  sync
  grep -q "boot ext2" /etc/mtab && (echo "=> filesystem EXT2 pour boot, ajout argument -a" && /usr/bin/time -f "\n%E elapsed" fsarchiver savefs -o -a -z7 -j$CORE BOOT.fsa $BOOT) || (echo "EXT3 ou EXT4 pour boot" && /usr/bin/time -f "\n%E elapsed" fsarchiver savefs -o -z7 -j$CORE BOOT.fsa $BOOT)
  mount -o remount,rw $BOOT
  sync
fi

echo -e "\033[40;1;32m=== CREATION DES SNAPSHOTS DES LV SYSTEME ===\033[0m"
for lv in $(cat lvm.out)
  do
  lvcreate -L1G -s -n `echo $lv | cut -d/ -f 4`snap `echo $lv`
  if [ $? -ne 0 ]
    then
    echo "Erreur : Creation du snapshot "`echo $lv | cut -d/ -f 4`snap `echo $lv`
    clean_exit
  fi
done

echo -e "\033[40;1;32m=== SAUVEGARDE DES SNAPSHOTS ===\033[0m\n"
for lv in $(cat lvm.out)
  do
  echo -e "\033[40;1;32m=> $lv sauvegarde sous isis:/mnt/nfsbackup/$HOST/`echo $lv | cut -d/ -f 4`.fsa \033[0m"
  /usr/bin/time -f "\n%E elapsed" fsarchiver savefs -o -z7 -j$CORE `echo $lv | cut -d/ -f 4`.fsa `echo $lv`snap
  if [ $? -ne 0 ]
    then
    echo "Erreur : fsarchiver "`echo $lv`snap
    clean_exit
  fi
  echo "----------------------------------------------"
  sleep 2
done

echo -e "\033[40;1;32m=== SUPPRESSION DES SNAPSHOTS ===\033[0m"
lvremove -f /dev/*/{slash,usr,opt,var,seos,home}*snap

sync

if [ ! -s ks-$HOST.cfg -a -s /root/*ks.cfg ]
  then
  echo "=> Recuperation du kickstart "
  cp /root/anaconda-ks.cfg /mnt/nfsbackup/$HOST/ks-$HOST.cfg
elif [ ! -s ks-$HOST.cfg -a -s /root/log_install/*ks.cfg ]
  then
  echo "=> Recuperation du kickstart "
  cp /root/log_install/anaconda-ks.cfg /mnt/nfsbackup/$HOST/ks-$HOST.cfg
else
  echo "=> Fichier kickstart deja recupere lors d'une precedente sauvegarde"
fi

echo -e "\033[40;1;32m=== SAUVEGARDE DU MBR ET DE LA TABLE DES PARTITIONS ===\033[0m\n"
BOOT_PART=$(cat /proc/partitions |awk '{print $4}' |grep -v "name"|grep -v "loop0" | grep -v '^$' | sed -n 1p)
echo $BOOT_PART
dd if=/dev/$BOOT_PART of=/mnt/nfsbackup/$HOST/$HOST.mbr.backup bs=512 count=1
sfdisk -d /dev/$BOOT_PART > /mnt/nfsbackup/$HOST/$HOST.partitions-table.backup

cd /
SIZE=$(du -sh /mnt/nfsbackup/$HOST | cut -f 1)
echo -e "\033[40;1;32m=== TAILLE DE LA SAUVEGARDE = $SIZE \033[0m"
ls -lh /mnt/nfsbackup/$HOST/*

END=$(date +%s)
DIFF=$(( $END - $START ))
echo -e "\033[40;1;32m=== DUREE DE LA SAUVEGARDE = $(($DIFF/60/60)) heure $(($DIFF/60%60 )) min $(($DIFF%60)) sec \033[0m"

DATE=`date +%Y_%m_%d-%H:%M`
echo "=> Fin ${DATE}"

echo -e "\033[40;1;32m=== CREATION DE backupLV POUR RESERVATION DES 6G NECESSAIRES AUX SNAPSHOTS ===\033[0m"

case $RHEL_VERSION in
  el5) lvcreate -L6144M -n backupLV $(grep usr /proc/mounts | head -n1 | cut -d/ -f3) ;;
  el6) lvcreate -L6144M -n backupLV $(grep usr /proc/mounts | head -n1 | cut -d- -f1) ;;
  *)
    echo "Erreur : OS Inconnu"
    clean_exit ;;
esac

} | tee $DIRLOG/$LOGFILE

clean_exit 0

# vim: syntax=sh:expandtab:shiftwidth=2:softtabstop=2
