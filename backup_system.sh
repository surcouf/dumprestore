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
# MAJ : 29/04/2016
#
# Utilisation de dump
# Script uniquement modifiable avec l'accord de INFRA UNIX
# OS : RHEL5 / RHEL6
###########################################################

# Pour des raisons de securite
umask 0077

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
  find /var/log -name "backup_*.out" -mtime +90 -exec rm {} \;
  chown ftpperf:ftpusers /var/log/backup*out
  chmod 644 /var/log/backup*out
  cp /var/log/backup*out ${DESTDIR} 2>/dev/null
  inform "== DEMONTAGE DU PARTAGE NFS ==="; echo
  umount -f ${NFS_DIR} 2>/dev/null
  exit ${RETURN}
}

trap clean_exit SIGHUP SIGINT SIGTERM

PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin:/opt/seos/bin:/root/bin
export PATH

# Verif root
if [[ ${EUID} -ne 0 ]]; then
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

NFS_DIR="/mnt/nfsbackup"
DESTDIR="${NFS_DIR}/${HOST}"
export NFS_DIR DESTDIR

RHEL_VERSION=$(lsb_release -sr)
case "${RHEL_VERSION}" in
  5|6) ;;
  *)
    echo "Erreur : OS non supporte !"
    clean_exit
  ;;
esac

DUMP=$(which dump)
if [[ $? -eq 1 ]]; then
  yum -q -y install dump
  DUMP=$(which dump)
fi

DUMP_OPTS="-u -j9"

DUMPLEVEL=0
DUMP_OPTS="${DUMP_OPTS} -${DUMPLEVEL}"

# snmpd is looking for /etc/dumpdates
#DUMPDATES="/etc/dumpdates"
if [[ -n "${DUMPDATES}" ]]; then
  DUMP_OPTS="${DUMP_OPTS} -D ${DUMPDATES}"
fi

# Releve de la config Hardware du serveur physique
if [ -x /root/hardware.sh -a -x /sbin/hpasmcli -a -x /sbin/hplog -a -x /opt/compaq/hpacucli/bld/hpacucli ]; then
  /root/hardware.sh show
elif [ -x /root/hardware.sh -a -x /opt/dell/srvadmin/bin/omreport ]; then
  /root/hardware.sh show
fi

{
  exec 2>&1
  START=$(date +%s)

  inform "=== SAUVEGARDE SYSTEME rh${RHEL_VERSION} ==="

  echo -e "\033[43;6;30m=== Log de l'execution du script ${DIRLOG}/${LOGFILE} ===\033[0m"
  echo "=> Debut ${DATE}"

  inform "=== SUPPRESSION DE SNAPSHOT EVENTUELLEMENT EXISTANT ==="
  lvscan | grep snap | egrep 'slash|usr|opt|var|seos|home'
  if [[ $? -eq 0 ]]; then
    case ${RHEL_VERSION} in
      5) lvremove -f /dev/$(grep usr /proc/mounts | head -n1 | cut -d/ -f3)/{slash,usr,opt,var,seos,home}*snap ;;
      6) lvremove -f $(grep usr /proc/mounts | head -n1 | cut -d- -f1)-{slash,usr,opt,var,seos,home}*snap ;;
      *)
        echo "Erreur : OS Inconnu"
        clean_exit ;;
     esac
  else
     echo "=> Aucun snapshot systeme detecte"
  fi

  inform "=== SUPPRESSION de backupLV - liberation des 6G reserves pour les snapshots ==="
  lvscan | grep -q backupLV
  if [[ $? -eq 0 ]]; then
    case ${RHEL_VERSION} in
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

  if [[ -d "${NFS_DIR}" ]]; then
    echo "=> Le repertoire ${NFS_DIR} existe "
  else
    echo "=> Creation du repertoire ${NFS_DIR}"
    mkdir -p ${NFS_DIR}
  fi

  grep -q "nfsbackup nfs" /etc/mtab
  if [[ $? -eq 0 ]]; then
    echo "=> Partage NFS deja monte"
  else
    echo "=> Montage du partage NFS"
    mount -t nfs4 r-isis.unix.intra.bdf.local:/home/svsys/appli/bdf/nfsbackup ${NFS_DIR}
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

  NFS_FREE=$(df -Pk ${NFS_DIR} | tail -1 | awk '{print $4}')
  if [[ ${NFS_FREE} -lt 10485760 ]]; then
    echo "Erreur : Place libre insuffisante sur le partage NFS"
    clean_exit
  fi

  case ${RHEL_VERSION} in
    5) lvdisplay | egrep -i 'slashlv|usrlv|optlv|varlv|seoslv|homelv' | awk '{ print $3 }' | sort > ${DESTDIR}/lvm.out ;;
    6) lvdisplay | grep -i "LV Path" | egrep -i 'slashlv|usrlv|optlv|varlv|seoslv|homelv' | awk '{ print $3 }' | sort > ${DESTDIR}/lvm.out ;;
    *)
      echo "Erreur : OS Inconnu"
      clean_exit ;;
  esac

  sync

  inform "=> Sauvegarde de la partition /boot sous isis:${DESTDIR}/boot.fsa"
  mount | grep -q boot
  if [[ $? -eq 0 ]]; then
    echo "Pas de partition /boot separe"
  else
    BOOT=$(mount | grep boot | awk '{print $1}')
    mount -o remount,ro ${BOOT}
    sync
    ${DUMP} ${DUMP_OPTS} -L boot -f ${DESTDIR}/BOOT.dump${DUMPLEVEL} ${BOOT}
    mount -o remount,rw ${BOOT}
    sync
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
    ${DUMP} ${DUMP_OPTS} -L ${lvname} -f ${DESTDIR}/${lvname}.dump.${DUMPLEVEL} ${lvsnap}
    if [[ $? -ne 0 ]]; then
      echo "Erreur : dump ${lvsnap}"
      clean_exit
    fi
    # Mise a jour de dumpdates avec le nom original du LV sauvegarde au lieu du snapshot.
    sed -i -e "s/${lvsnap}/${lv}/" ${DUMPDATES}
    echo "----------------------------------------------"
    sleep 2
  done

  inform "=== SUPPRESSION DES SNAPSHOTS ==="
  lvremove -f /dev/*/{slash,usr,opt,var,seos,home}*snap

  sync

  if [ ! -s ks-${HOST}.cfg -a -s /root/*ks.cfg ]; then
    echo "=> Recuperation du kickstart "
    cp /root/anaconda-ks.cfg ${DESTDIR}/ks-${HOST}.cfg
  elif [ ! -s ks-${HOST}.cfg -a -s /root/log_install/*ks.cfg ]; then
    echo "=> Recuperation du kickstart "
    cp /root/log_install/anaconda-ks.cfg ${DESTDIR}/ks-${HOST}.cfg
  else
    echo "=> Fichier kickstart deja recupere lors d'une precedente sauvegarde"
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

  case "${RHEL_VERSION}" in
    5) lvcreate -L6144M -n backupLV $(grep usr /proc/mounts | head -n1 | cut -d/ -f3) ;;
    6) lvcreate -L6144M -n backupLV $(grep usr /proc/mounts | head -n1 | cut -d- -f1) ;;
    *)
      echo "Erreur : OS Inconnu"
      clean_exit ;;
  esac

} | tee ${DIRLOG}/${LOGFILE}

clean_exit 0

# vim: syntax=sh:expandtab:shiftwidth=2:softtabstop=2
