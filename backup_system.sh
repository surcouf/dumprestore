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

# Variables

VERSION=2.00

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/seos/bin:/root/bin

HOST=$(hostname -s)

DATE=$(date +%Y_%m_%d-%H:%M)

DIRLOG=/var/log
LOGFILE=backup_${HOST}_$(date +\%Y_\%m_\%d).out

NFS_SERVER="r-isis.unix.intra.bdf.local"
NFS_DIR="/home/svsys/appli/bdf/nfsbackup"

MNTDIR="/mnt/nfsbackup"
DESTDIR="${MNTDIR}/${HOST}"

RHEL_VERSION=$(lsb_release -sr)
CORE=$(grep -c 'processor' /proc/cpuinfo)

BLKID="blkid -s TYPE -o value"

export PATH LOGFILE MNTDIR DESTDIR CORE

# Functions

print_msg() {
  #
  # Affiche un message selon la couleur fournie
  # Exemple : 
  #  print_msg -f GREEN "Message"
  #
  local COL_STR="\e[39;0m"  # Default foreground color
  local COL_RESET="\e[39;49;0m"
  local params=$(getopt -o nf: -l newline,foreground: -- "$@")
  eval set -- "${params}"
  while true; do
    case "$1" in
      -n|--newline) COL_RESET="${COL_RESET}\n"; shift ;;
      -f|--foreground)
        case "$2" in
          BLACK)    COL_STR="\e[30;1m"  ;;
          RED)      COL_STR="\e[31;1m"  ;;
          GREEN)    COL_STR="\e[32;1m"  ;;
          YELLOW)   COL_STR="\e[33;1m"  ;;
          BLUE)     COL_STR="\e[34;1m"  ;;
          MAGENTA)  COL_STR="\e[35;1m"  ;;
          CYAN)     COL_STR="\e[36;1m"  ;;
        esac
        shift 2 ;;
      --) shift; break;;
    esac
  done

  printf '%b%s%b' "${COL_STR}" "$@" "${COL_RESET}"
}

notice() {
  print_msg --newline "$@"
}

inform() {
  print_msg --newline --foreground GREEN "$@"
}

warning() {
  print_msg --newline --foreground YELLOW "$@"
}

error() {
  print_msg --newline --foreground RED "$@" >&2
}

# Pour sortir proprement
clean_exit() {
  RETURN=${1:-3}
  find /var/log -name "backup_*.out" -mtime +90 -delete
  chown ftpperf:ftpusers /var/log/backup*out
  chmod 644 /var/log/backup*out
  cp /var/log/backup*out ${DESTDIR} 2>/dev/null
  inform "== DEMONTAGE DU PARTAGE NFS ==="; echo
  umount -f ${MNTDIR} 2>/dev/null
  exit ${RETURN}
}

dump_fs() {
  local DEV=$1
  local FILE=$2
  local FS=$(${BLKID} ${DEV})

  local DUMP="fsarchiver savefs"
  local DUMP_OPTS="-o -z7 -j${CORE}"

  case "${FS}" in
    ext2)
      DUMP_OPTS="-a ${DUMP_OPTS}"
      ;;
    xfs)  ;; #TODO
  esac

  inform "=> Sauvegarde de ${DEV} sous isis:${NFSDIR}/${file}"
  /usr/bin/time -f "\n%E elapsed" ${DUMP} ${DUMP_OPTS} ${FILE} ${DEV}
  if [[ $? -ne 0 ]]; then
    error "Erreur : fsarchiver ${snap}"
    clean_exit
  fi
  return $?
}

# Main 

umask 0077

trap clean_exit SIGHUP SIGINT SIGTERM

# Verif root
if [[ ${EUID} -ne 0 ]]; then
  echo "Ce script doit etre lance en tant que root" 1>&2
  exit 1
fi

case "${RHEL_VERSION%.*}" in
  5|6) ;;
  *)
    echo "Erreur : OS non supporte !"
    clean_exit
    ;;
esac

case "${HOST:2:2}" in
  dv|re) ENV=development;;
  in)    ENV=integration;;
  pr|ho) ENV=production;;
  *)     ENV=test;;
esac

# Hardware configuration report 
if [[ -x /root/hardware.sh ]]; then
  /root/hardware.sh show
fi

{
  exec 2>&1
  START=$(date +%s)

  # fsarchiver ne supporte que jusqu'a 32 jobs simulatnes. On limite donc CORE a 32.
  if [[ ${CORE} -gt 32 ]]; then
    export CORE=32
  fi

  inform "=== SAUVEGARDE SYSTEME RHEL ${RHEL_VERSION} ==="

  warning "=== Log de l'execution du script ${DIRLOG}/${LOGFILE} ==="
  echo "=> Debut ${DATE}"

  LVS=( $(lvs --noheading -o lv_path systemVG) )

  inform "=== SUPPRESSION DE SNAPSHOT EVENTUELLEMENT EXISTANT ==="
  for lv in ${LVS[*]}; do
    snap="${lv}snap"
    if [[ -e ${snap} ]]; then 
      lvremove -f ${snap}
    fi
  done

  inform "=== SUPPRESSION de backupLV - liberation des 6G reserves pour les snapshots ==="
  lvscan | grep -q backupLV
  if [[ $? -eq 0 ]]; then
    case "${RHEL_VERSION%.*}" in
      5) lvremove -f /dev/$(grep usr /proc/mounts | head -n1 | cut -d/ -f3)/backupLV ;;
      6) lvremove -f $(grep usr /proc/mounts | head -n1 | cut -d- -f1)/backupLV ;;
      *)
        echo "Erreur : OS Inconnu"
        clean_exit ;;
    esac
  else
    echo "=> backupLV n'existe pas"
  fi

  inform "=== MONTAGE DU PARTAGE NFS POUR DEPOT DE LA SAUVEGARDE ==="

  if [[ -d "${MNTDIR}" ]]; then
    echo "=> Le repertoire ${MNTDIR} existe "
  else
    echo "=> Creation du repertoire ${MNTDIR}"
    mkdir -p ${MNTDIR}
  fi

  grep -q "nfsbackup nfs" /etc/mtab
  if [[ $? -eq 0 ]]; then
    echo "=> Partage NFS deja monte"
  else
    echo "=> Montage du partage NFS"
    mount -t nfs4 ${NFS_SERVER}:${NFS_DIR} ${MNTDIR}
    if [[ $? -ne 0 ]]; then
      echo "Erreur : Montage NFS"
      clean_exit
    fi
  fi

  if [[ -d "${DESTDIR}" ]]; then
    echo "=> Le repertoire ${DESTDIR} existe"
  else
    echo "=> Creation du repertoire qui va accueillir la sauvegarde du serveur"
    mkdir ${DESTDIR}
  fi

  NFS_FREE=$(df -Pk ${MNTDIR} | tail -1 | awk '{print $4}')
  if [[ ${NFS_FREE} -lt 10485760 ]]; then
    echo "Erreur : Place libre insuffisante sur le partage NFS"
    clean_exit
  fi

  FSARCHIVER=$(which fsarchiver)
  if [[ $? -eq 1 ]]; then
    case "${RHEL_VERSION%.*}" in
      5)
        echo "=> fsarchiver introuvable, recuperation du binaire"
        cp ${MNTDIR}/fsarchiver-el5/fsarchiver /usr/local/sbin/
        FSARCHIVER="/usr/local/sbin/fsarchiver"
        chmod ug+x ${FSARCHIVER}
      ;;
      6)
        yum -q -y install fsarchiver
        FSARCHIVER=$(which fsarchiver)
      ;;
    esac
  fi
  FSARCHIVER_OPTS="-o -z7 -j${CORE}"

  case "${RHEL_VERSION%.*}" in
    5) lvdisplay | egrep -i 'slashlv|usrlv|optlv|varlv|seoslv|homelv' | awk '{ print $3 }' | sort > ${DESTDIR}/lvm.out ;;
    6) lvdisplay | grep -i "LV Path" | egrep -i 'slashlv|usrlv|optlv|varlv|seoslv|homelv' | awk '{ print $3 }' | sort > ${DESTDIR}/lvm.out ;;
    *)
      echo "Erreur : OS Inconnu"
      clean_exit ;;
  esac

  sync

  BOOT=$(mount | grep boot)
  if [[ $? -ne 0 ]]; then
      echo "Pas de partition /boot separe"
  else
      BOOT="${BOOT%% *}"
      mount -o remount,ro ${BOOT}
      sync
      dump_fs ${BOOT} ${NFSDIR}/BOOT.fsa
      mount -o remount,rw ${BOOT}
      sync
  fi

  # Sauvegarde de la configuration des volumes LVM
  warning "=== SAUVEGARDE DE LA CONFIGURATION LVM de systemVG ==="
  vgcfgbackup systemVG -f "${NFSDIR}/systemVG.cfg"
  if [[ $? -eq 0 ]]; then
      echo "Configuration LVM sauvegardée."
  else
      echo "Erreur lors de la copie de la configuration LVM"
      clean_exit
  fi

  inform "=== CREATION DES SNAPSHOTS DES LV SYSTEME ==="
  for lv in $(cat ${DESTDIR}/lvm.out); do
    local lvsnap="${lvname}snap"
    local lvname=${lv##/*}
    lvcreate -L1G -s -n ${lvsnap} ${lv}
    if [[ $? -ne 0 ]]; then
      echo "Erreur : Creation du snapshot ${lvsnap} ${lv}"
      clean_exit
    fi
  done

  inform "=== SAUVEGARDE DES SNAPSHOTS ==="
  for lv in $(cat ${DESTDIR}/lvm.out); do
    local lvsnap="${lv}snap"
    local lvname=${lv##/*}
    inform "=> ${lv} sauvegarde sous isis:${DESTDIR}/${lvname}.fsa"
    /usr/bin/time -f "\n%E elapsed" ${FSARCHIVER} savefs ${FSARCHIVER_OPTS} ${DESTDIR}/${lvname}.fsa ${lvsnap}
    if [[ $? -ne 0 ]]; then
      echo "Erreur : fsarchiver ${lvsnap}"
      clean_exit
    fi
    echo "----------------------------------------------"
    sleep 2
  done

  inform "=== SUPPRESSION DES SNAPSHOTS ==="
  lvremove -f /dev/*/{slash,usr,opt,var,seos,home}*snap

  sync

  if [[ -s ${DESTDIR}/ks-${HOST}.cfg ]];then
    echo "=> Fichier kickstart deja recupere lors d'une precedente sauvegarde"
  else
    if [[ -s /root/anaconda-ks.cfg ]]; then
      echo "=> Recuperation du kickstart "
      cp /root/anaconda-ks.cfg ${DESTDIR}/ks-${HOST}.cfg
    elif [[ -s /root/log_install/anaconda-ks.cfg ]]; then
      echo "=> Recuperation du kickstart "
      cp /root/log_install/anaconda-ks.cfg ${DESTDIR}/ks-${HOST}.cfg
    fi
  fi

  inform "=== SAUVEGARDE DU MBR ET DE LA TABLE DES PARTITIONS ==="
  BOOT_PART=$(awk '{print $4}' /proc/partitions |egrep -v '(name|loop0|^$)' | sed -n 1p)
  echo ${BOOT_PART}
  dd if=/dev/${BOOT_PART} of=${DESTDIR}/${HOST}.mbr.backup bs=512 count=1
  sfdisk -d /dev/${BOOT_PART} > ${DESTDIR}/${HOST}.partitions-table.backup

  cd /
  SIZE=$(du -sh ${DESTDIR} | cut -f 1)
  inform "=== TAILLE DE LA SAUVEGARDE = ${SIZE}"
  ls -lh ${DESTDIR}/*

  END=$(date +%s)
  DIFF=$(( ${END} - ${START} ))
  inform "=== DUREE DE LA SAUVEGARDE = $((${DIFF}/60/60)) heure $((${DIFF}/60%60 )) min $((${DIFF}%60)) sec"

  DATE=`date +%Y_%m_%d-%H:%M`
  echo "=> Fin ${DATE}"

  inform "=== CREATION DE backupLV POUR RESERVATION DES 6G NECESSAIRES AUX SNAPSHOTS ==="

  case "${RHEL_VERSION%.*}" in
    5) lvcreate -L6144M -n backupLV $(grep usr /proc/mounts | head -n1 | cut -d/ -f3) ;;
    6) lvcreate -L6144M -n backupLV $(grep usr /proc/mounts | head -n1 | cut -d- -f1) ;;
    *)
      echo "Erreur : OS Inconnu"
      clean_exit ;;
  esac

} | tee ${DIRLOG}/${LOGFILE}

clean_exit 0

# vim: syntax=sh:expandtab:shiftwidth=2:softtabstop=2
