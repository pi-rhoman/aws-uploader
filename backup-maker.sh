#!/bin/bash

# Where do we store the fragments
# by default store in current directory
fragmentsdir=.
while getopts "f:" flag
do
	case "${flag}" in
		f) fragmentsdir=${OPTARG};; 
	esac
done
shift $((OPTIND - 1))

BACKUP_FILE=`realpath $1`
BACKUP_FILENAME=`basename $BACKUP_FILE`
BUCKET_NAME=liams-computer-backup
FRAGMENT_COUNT=5
# Get the CRC32 of the file
CRC=`crc32 $BACKUP_FILE`

# Split the file into fragments
if [ ! -d $fragmentsdir ]; then
	printf '%s\n' "fragments directory does not exist" >&2
	exit 1
fi
# change directory to fragments 
cd $fragmentsdir
split -n $FRAGMENT_COUNT --numeric-suffixes=1 $BACKUP_FILE $BACKUP_FILENAME. 

get_upload () {
	echo `aws s3api list-multipart-uploads --bucket $BUCKET_NAME | jq ".Uploads.[] | select(.Key == \"$BACKUP_FILENAME\")"`
}


# Resume from multipart upload or start a new one
if [[ ! $(get_upload) ]]; then
	aws s3api create-multipart-upload --bucket $BUCKET_NAME --key $BACKUP_FILENAME --checksum-algorithm CRC32 --checksum-type FULL_OBJECT
	echo "created upload `echo $(get_upload) | jq \".uploadid\"`"
else
	echo "Resuming from upload id `echo $(get_upload) | jq \".UploadId\"`"
fi
UPLOAD_ID=`echo $(get_upload) | jq -r ".UploadId"`

# Upload each part individually
for part in ./$BACKUP_FILENAME*; do
	# get the part number from the file extension
	PART_NUMBER=${part##*.}
	aws s3api upload-part --bucket $BUCKET_NAME --key $BACKUP_FILENAME --part-number $PART_NUMBER --body $part --upload-id $UPLOAD_ID --checksum-algorithm CRC32
done

FILE_PARTS="{
	\"Parts\": []
}" 
for part in ./$BACKUP_FILENAME*; do
	PART_NUMBER=${part##*.}
	PART_CRC32=`crc32 $part | xxd -r -p | base64`
	ETAG=($(md5sum $part))
	FILE_PARTS=`echo $FILE_PARTS | jq --argjson part_number $PART_NUMBER --arg part_crc32 "$PART_CRC32" --arg etag "${ETAG}" '.Parts += [{"PartNumber":$part_number, ETag:$etag, ChecksumCRC32:$part_crc32}]'`
done
echo $FILE_PARTS > fileparts.json
	

aws s3api complete-multipart-upload --multipart-upload file://fileparts.json --bucket $BUCKET_NAME --key $BACKUP_FILENAME --upload-id $UPLOAD_ID --checksum-type FULL_OBJECT
