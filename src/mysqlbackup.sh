#!/bin/bash
###################################################################
#Script Name	: MySQL Backup                                                                                          
#Description	: Backup script to dump your databases using mysqldump, archive the databases in a single ZIP archive then backup the archive by email, copy, scp or S3.                                                                                
#Args           : help | version                                                                                           
#Author       	: Ramone Burrell                                              
#Email         	: ramone@ramoneburrell.com
#Environment variables : MYSQL_BACKUP_ENV                                
###################################################################
version="0.0.1-alpha"
version_text="MySQL Backup v${version}"
wd=$(dirname $0)
wd=$(realpath $wd)
datetime=$(date | sed -E 's/\s/-/g' | sed -E 's/:/-/g')
timestamp=$(date +%s)
methods=('email' 'copy' 'scp' 's3')
emailHead=''
emailTail=''
config_file_path='conf.ini'

if ! [[ -z $MYSQL_BACKUP_ENV ]]; then
	archive_filename="database_backups_${MYSQL_BACKUP_ENV}_${datetime}.zip";
else
	archive_filename="database_backups_${datetime}.zip";
fi

### FUNCTIONS ###
function validateEmailMethodConfig() {
	#CA cert
	if [[ -z "$cacert" ]]; then
		error "CA cert not set."
		exit 1;
	fi

	if ! [[ -f $cacert ]]; then
		error "CA cert '$cacert' does not exist."
		exit 1
	fi

	if [[ -z "$smtp_host" ]]; then
		error "SMTP host not set."
		exit 1;
	fi

	if [[ -z "$smtp_port" ]]; then
		error "SMTP port not set."
		exit 1;
	fi

	if [[ -z "$smtp_login_options" ]]; then
		error "SMTP login options not set."
		exit 1;
	fi

	if [[ -z "$mail_from_name" ]]; then
		error "Mail from name not set."
		exit 1;
	fi

	if [[ -z "$mail_from" ]]; then
		error "Mail from email address not set."
		exit 1;
	fi
	
	if [[ -z "$mail_from_password" ]]; then
		error "Mail from password not set."
		exit 1;
	fi
	
	if [[ -z "$mail_rcpt_name" ]]; then
		error "Mail RCPT name not set."
		exit 1;
	fi

	if [[ -z "$mail_rcpt" ]]; then
		error "Mail RCPT not set."
		exit 1;
	fi

	if [[ -z "$no_reply_email" ]]; then
		error "No reply email address not set"
		exit 1;
	fi
}

function validateScpMethodConfig() {
	if [[ -z "$scp_user" ]]; then
		error "scp user not set."
		exit 1;
	fi
	
	if [[ -z "$scp_host" ]]; then
		error "scp host not set."
		exit 1;
	fi
	
	if [[ -z "$scp_path" ]]; then
		error "scp path not set."
		exit 1;
	fi
	
	if [[ -z "$scp_identity_file" ]]; then
		error "scp identity file not set."
		exit 1;
	fi
	
	if ! [[ -f $scp_identity_file ]]; then
		error "scp identity file '$scp_identity_file' does not exist."
		exit 1
	fi
}

function validateS3MethodConfig() {
	if [[ -z "$s3_host" ]]; then
		error "S3 host not set."
		exit 1;
	fi

	if [[ -z "$s3_access_key" ]]; then
		error "S3 access key not set."
		exit 1;
	fi
	
	if [[ -z "$s3_secret_key" ]]; then
		error "S3 secret key not set."
		exit 1;
	fi

	if [[ -z "$s3_bucket" ]]; then
		error "S3 bucket not set."
	    exit 1;
	fi
}

function validateConfig() {
	if ! [[ ${methods[@]} =~ $method ]]; then
		error "Backup method '$method' is not supported."
	    exit 1;
	fi

	#MySQL Defaults file
	if [[ -z "$mysql_defaults_file" ]]; then
		#check that mysql host, user, and password are provided

		if [[ -z "$mysql_host" ]]; then
			error "MySQL host not set."
			exit 1;
		fi

		if [[ -z "$mysql_user" ]]; then
			error "MySQL user not set."
			exit 1;
		fi

		if [[ -z "$mysql_password" ]]; then
			error "MySQL password not set."
			exit 1;
		fi
	else
		#test that it is actully a file
		if ! test -f "$mysql_defaults_file"; then
			error "MySQL defaults file '$mysql_defaults_file' does not exist."
			exit 1;
		fi
	fi

	if [ ${#databases[@]} -eq 0 ]; then
		error "No databases set to backup."
		exit 1;
	fi
	
	case $method in

		'copy')
			if [[ -z "$copy_to" ]]; then
				error "Copy to path not set."
				exit 1;
			fi
	    ;;

		'scp')
			#scp
			validateScpMethodConfig
	    ;;

		's3')
			#s3
			validateS3MethodConfig

			#Then try to install Minio Client if not installed
			s3_bin=$(whereis -b mc | grep '/')

			if [[ -z $s3_bin ]]; then
				answer=''

				while  [[ $answer != "N" ]] && [[ $answer != "Y" ]]; do
					read -p "$(tput setaf 2)Minio Client is not installed. Do you want to install it to continue? [Y=yes,N=No]: $(tput sgr0)" answer
				
					if [[ $answer != "N" ]] && [[ $answer != "Y" ]]; then
						error "Invalid answer '$answer'"
					else
						break
					fi
				done

				if [[ $answer == "N" ]]; then
					echo "Ok"
					exit 0
				fi

				installMc
			fi

			#Set S3 service alias
			if [[ -z $s3_port ]]; then
				s3_port='9000'
			fi

			alias='mysql_database_backup_s3'
			
			mc alias set $alias/ https://$s3_host:$s3_port $s3_access_key $s3_secret_key

			#Check if bucket exists and ask to create it if not
			mc ls $alias/$s3_bucket >> /dev/null 2>&1

			if [[ $? != 0 ]]; then
				answer=''

				while  [[ $answer != "N" ]] && [[ $answer != "Y" ]]; do
					read -p "$(tput setaf 2)Bucket '$s3_bucket' does not exist. Do you want to create it? [Y=yes,N=No]: $(tput sgr0)" answer
				
					if [[ $answer != "N" ]] && [[ $answer != "Y" ]]; then
						error "Invalid answer '$answer'"
					else
						break
					fi
				done

				if [[ $answer == "N" ]]; then
					echo "Ok"
					exit 0
				fi

				mc mb $alias/$s3_bucket

				if [[ $status -ne 0 ]]; then
					error "Failed to create S3 bucket '$s3_bucket'."
					cleanup
					failed
					exit 1
				fi
			fi
		;;

		*)
			#email
			validateEmailMethodConfig
	    ;;
	esac
}

function installMc() {
	wget https://dl.min.io/client/mc/release/linux-amd64/mc
	chmod +x mc

	copy_mc=''

	while [[ $copy_mc != 'Y' ]] && [[ $copy_mc != 'N' ]]; do
		read -s -p "$(tput setaf 2)Do you want to move the Minio Client binary to /usr/bin/ ?: [Y=yes,N=No]$(tput sgr0)" copy_mc
    done

	if [[ $copy_mc == 'Y' ]]; then
	    sudo mv mc /usr/bin/
		echo "$(tput setaf 4)Moved Minio Client binary to /usr/bin/'$(tput sgr0)"
	fi
}

function getEmailHead(){
	emailHead="From: <MAIL_FROM_NAME> <<MAIL_FROM>>
To: <MAIL_RCPT_NAME> <<MAIL_RCPT>>
MIME-Version: 1.0
Content-Type: multipart/mixed; boundary=\"cAyrUzTUPPdpH17GuvThhNwXoaFxTv4A=:<UNIX_TIMESTAMP>\"
Subject: Database Backup
Reply-To: No-Reply <<NO_REPLY_EMAIL>>

--cAyrUzTUPPdpH17GuvThhNwXoaFxTv4A=:<UNIX_TIMESTAMP>
Content-Type: text/plain; charset=UTF-8
Content-Disposition: inline
Content-Transfer-Encoding: 8bit

<EMAIL_BODY>

--cAyrUzTUPPdpH17GuvThhNwXoaFxTv4A=:<UNIX_TIMESTAMP>
Content-Type: application/octet-stream; name=\"<ARCHIVE_NAME>\"
Content-Disposition: attachment; filename=\"<ARCHIVE_NAME>\"
Content-Transfer-Encoding: base64


"
}

function getEmailTail(){
	emailTail="--cAyrUzTUPPdpH17GuvThhNwXoaFxTv4A=:<UNIX_TIMESTAMP>"
}

function emailDatabasesArchive() {
	getEmailHead
	getEmailTail
	
	base64 temp/$archive_filename > temp/archive.base64
	echo "$emailHead" > temp/email.eml
	cat temp/archive.base64 >> temp/email.eml
	echo "$emailTail" >> temp/email.eml
	
	#stream edit
	sed -i "s/<ARCHIVE_NAME>/$archive_filename/g" temp/email.eml
	sed -i "s/<UNIX_TIMESTAMP>/$timestamp/g" temp/email.eml
	sed -i "s/<MAIL_FROM_NAME>/$mail_from_name/g" temp/email.eml
	sed -i "s/<MAIL_FROM>/$mail_from/g" temp/email.eml
	sed -i "s/<MAIL_RCPT_NAME>/$mail_rcpt_name/g" temp/email.eml
	sed -i "s/<MAIL_RCPT>/$mail_rcpt/g" temp/email.eml
	sed -i "s/<NO_REPLY_EMAIL>/$no_reply_email/g" temp/email.eml
	sed -i "s/<EMAIL_BODY>/$email_body/g" temp/email.eml

	curl --ssl \
	  --url "smtp://$smtp_host:$smtp_port" \
	  --tlsv1.2 \
	  --cacert $cacert \
	  --login-options "$smtp_login_options" \
	  --mail-from $mail_from \
	  --mail-rcpt $mail_rcpt \
	  --user "$mail_from:$mail_from_password" \
	  --upload-file temp/email.eml

	status=$?
		
	if [[ $status -ne 0 ]]; then
		error "Failed to make CURL request."
		cleanup
		failed
		exit 1
	fi
}

function cleanup() {
	echo "Cleaning up ..."
	
	shopt -s nullglob

	#create array with all the files temp/
	tempfiles=(temp/*)

	for file in "${tempfiles[@]}"; do
	   	echo "Removing $file ..."
		rm $file
	done

	echo "Removing temp directory ..."
	rm -rf temp/
}

function failed(){
	error "Backup failed"
}

function error(){
	echo "$(tput setaf 1)$1$(tput sgr0)"
}

function success(){
	echo "$(tput setaf 2)$1$(tput sgr0)"
}
## END FUNCTIONS ###

case $1 in
	'help')
		success "Please see: https://github.com/burrellramone/mysqlbackup"
		exit 0
	;;

  	'version')
		success "$version_text"
		exit 0
	;;

	*)
		if ! [[ -z $1 ]]; then
			config_file_path=$1
		fi
	;;
esac

## BEGIN WORK ##
echo "Working directory: $wd"
cd "$wd"

#does ini file exist?
if ! test -f $config_file_path; then
  error "Configuration file '$config_file_path' does not exist."
  exit 1;
fi

echo "Configuration file: $config_file_path"

#read ini values
source <(grep = $config_file_path)

echo "Backup Method: $method"

#Validate configuration
validateConfig

#make temp directory
echo "Creating temp directory temp/ ..."
mkdir -p temp

echo "Databases: ${databases[*]}"

for database in "${databases[@]}"
do
	out_filename=''

	if ! [[ -z $MYSQL_BACKUP_ENV ]]; then
		out_filename="${database}_${MYSQL_BACKUP_ENV}_$datetime.sql";
	else
		out_filename="${database}_${datetime}.sql";
	fi

	echo "Dumping $database ..."
	
	#Use defaults file
	if ! [[ -z $mysql_defaults_file ]]; then
		mysqldump --defaults-file=$mysql_defaults_file \
					--default-character-set=utf8 \
					--dump-date \
					--events \
					--routines=true \
					--databases $database > temp/$out_filename
	else
		#else use host, user, password and port provided in config file
		if [[ -z $mysql_port ]]; then
			mysql_port='3306'
		fi

		mysqldump --host=$mysql_host --user=$mysql_user --password=$mysql_password --port=$mysql_port \
					--default-character-set=utf8 \
					--dump-date \
					--events \
					--routines=true \
					--databases $database > temp/$out_filename
	fi

	status=$?

	if [[ $status -ne 0 ]]; then
		error "Failed to dump database '$database'."
		cleanup
		failed
		exit 1
	fi

	(cd temp && zip -u $archive_filename $out_filename)
				
done

case $method in

  	'copy')
	#copy archive
	#create copy path is not exist
	mkdir -p $copy_to
	cp temp/$archive_filename $copy_to 
    
	status=$?

	if [[ $status -ne 0 ]]; then
		error "Failed to copy temp/$archive_filename to $copy_to"
		exit 1
	fi
    ;;

  	'scp')
	#scp archive
    	echo "Copying temp/$archive_filename to $scp_user@$scp_host:$scp_path ..."
    	
    	#set scp_port to 22 if it is not set
    	if [[ -z "$scp_port" ]]; then
		scp_port=22
	fi
    
    	scp -p -i $scp_identity_file -P $scp_port temp/$archive_filename $scp_user@$scp_host:$scp_path
    	
    	status=$?

	if [[ $status -ne 0 ]]; then
		error "Failed to copy temp/$archive_filename to $scp_user@$scp_host:$scp_path"
		exit 1
	fi
    ;;

	's3')
		mc cp --tags "name=$archive_filename" temp/$archive_filename mysql_database_backup_s3/$s3_bucket/$archive_filename
		
		if [[ $? -ne 0 ]]; then
			error "Failed to copy temp/$archive_filename to S3 bucket."
			cleanup
			failed
			exit 1
		fi
	;;

  	*)
    #email archive
	emailDatabasesArchive
    ;;
esac

	
cleanup

echo "Done!";
