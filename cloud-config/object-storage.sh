#!/bin/bash

pwd_set () {
  cd /root/
}

dl_kubernetes_archive () {
  curl -sSL RELEASE_URL -O && \
  KUBE_TAR="kubernetes.tar.gz"
}

unpack_kubernetes_archive () {
  if [ ! -f $KUBE_TAR ];
  then
     echo "kubernetes.tar.gz not found"; exit 1
  else
    tar -xvzf kubernetes.tar.gz
  fi
}

dl_minio () {
  wget https://dl.minio.io/server/minio/release/linux-amd64/minio && \
  cp minio /usr/local/bin/minio && \
  chmod +x /usr/local/bin/minio
}

check_minio_config () {

    mkdir -p .minio

}

config_minio () {
  if [ "$(which minio)" == "" ]; then
    echo "Can't find minio in PATH, please fix and retry."
    exit 1
  fi

  if [ ! -f minio ]; then
    echo "minio not found"; exit 1
  fi

  if [ -f .minio.config.json ]; then
    cp .minio/config.json .minio/config.json.bak
  else
    echo -e ".minio/config.json not found\n" && \
    touch .minio/config.json
  fi

  echo '{
  	"version": "7",
  	"credential": {
  		"accessKey": "MINIO_KEY",
  		"secretKey": "MINIO_SECRET"
  	},
  	"region": "us-east-1",
  	"logger": {
  		"console": {
  			"enable": true,
  			"level": "fatal"
  		},
  		"file": {
  			"enable": false,
  			"fileName": "",
  			"level": ""
  		},
  		"syslog": {
  			"enable": false,
  			"address": "",
  			"level": ""
  		}
  	},
  	"notify": {
  		"amqp": {
  			"1": {
  				"enable": false,
  				"url": "",
  				"exchange": "",
  				"routingKey": "",
  				"exchangeType": "",
  				"mandatory": false,
  				"immediate": false,
  				"durable": false,
  				"internal": false,
  				"noWait": false,
  				"autoDeleted": false
  			}
  		},
  		"elasticsearch": {
  			"1": {
  				"enable": false,
  				"url": "",
  				"index": ""
  			}
  		},
  		"redis": {
  			"1": {
  				"enable": false,
  				"address": "",
  				"password": "",
  				"key": ""
  			}
  		}
  	}
  }' >> .minio/config.json

  if [ -d "kubernetes" ]; then
    minio server kubernetes
  else
    echo -e "`pwd`/kubernetes not found\n"; exit 1
  fi
}

pwd_set && \
dl_kubernetes_archive && \
unpack_kubernetes_archive && \
dl_minio && \
check_minio_config && \
config_minio
