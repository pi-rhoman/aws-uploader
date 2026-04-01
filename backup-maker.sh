#!/bin/bash

# Where do we store the fragments
# by default store in current directory
usage () {
	printf '%s\n' "Usage: ./backup-maker -f <fragments directory> [backup file]" >&2 && exit 1
}
while getopts ":f:" flag
do
	case "${flag}" in
		f) fragmentsdir=${OPTARG};; 
		*) $(usage) || exit $?
	esac
done
shift $((OPTIND - 1))

BACKUP_FILE=`realpath $1`
BACKUP_FILENAME=`basename $BACKUP_FILE`
BUCKET_NAME=liams-computer-backup
FRAGMENT_COUNT=200
# Get the CRC32 of the file
CRC=`crc32 $BACKUP_FILE`

# Split the file into fragments
if [ ! $fragmentsdir ]; then
	$(usage) || exit $?
elif [ ! -d $fragmentsdir ]; then
	printf '%s\n' "fragments directory does not exist" >&2
	exit 1
fi
cd $fragmentsdir
split -n $FRAGMENT_COUNT --numeric-suffixes=1 $BACKUP_FILE $BACKUP_FILENAME. 

get_upload () {
	echo `aws s3api list-multipart-uploads --bucket $BUCKET_NAME | jq ".Uploads.[] | select(.Key == \"$BACKUP_FILENAME\")"`
}


# Resume from multipart upload or start a new one
if [[ ! $(get_upload) ]]; then
	aws s3api create-multipart-upload --bucket $BUCKET_NAME --key $BACKUP_FILENAME --checksum-algorithm CRC32 --checksum-type FULL_OBJECT
	UPLOAD_ID=`echo $(get_upload) | jq -r ".UploadId"`
	echo "Created upload $UPLOAD_ID"
else
	UPLOAD_ID=`echo $(get_upload) | jq -r ".UploadId"`
	echo "Resuming from upload id $UPLOAD_ID"
fi
UPLOADED_PARTS=`aws s3api list-parts --bucket $BUCKET_NAME --key $BACKUP_FILENAME --upload-id $UPLOAD_ID`	

# Upload each part individually
for part in ./$BACKUP_FILENAME*; do
	# get the part number from the file extension
	PART_NUMBER=${part##*.}
	# Find the previously uploaded version of the part if it extsts
	PRIOR_UPLOAD=`echo $UPLOADED_PARTS | jq --argjson part_number $PART_NUMBER '.Parts.[] | select(.PartNumber == $part_number)'`
	if [ ! -z "$PRIOR_UPLOAD" ] ; then
		echo "Checking $PART_NUMBER"
		PART_CRC32=`crc32 $part | xxd -r -p | base64`
		CRC_MATCHES=`echo $PRIOR_UPLOAD | jq --arg part_crc $PART_CRC32 '.ChecksumCRC32 == $part_crc'`
		if [ "$CRC_MATCHES" == "false" ] ; then
			echo "Checksum mismatch with uploaded part $PRIOR_UPLOAD expected $PART_CRC32. Reuploading..."
		else
			continue
		fi 
	fi
	echo "Uploading $PART_NUMBER"
	aws s3api upload-part --bucket $BUCKET_NAME --key $BACKUP_FILENAME --part-number $PART_NUMBER --body $part --upload-id $UPLOAD_ID --checksum-algorithm CRC32
done

# Complete the upload
FILE_PARTS="{
	\"Parts\": []
}" 
for part in ./$BACKUP_FILENAME*; do
	PART_NUMBER=${part##*.}
	
	PART_CRC32=`crc32 $part | xxd -r -p | base64`
	ETAG=($(md5sum $part))
	FILTER='.Parts += [{"PartNumber":$part_number, ETag:$etag, ChecksumCRC32:$part_crc32}]'
	FILE_PARTS=`echo $FILE_PARTS | jq --argjson part_number $PART_NUMBER --arg part_crc32 "$PART_CRC32" --arg etag "${ETAG}" $FILTER` 
done
echo $FILE_PARTS > fileparts.json
aws s3api complete-multipart-upload --multipart-upload file://fileparts.json --bucket $BUCKET_NAME --key $BACKUP_FILENAME --upload-id $UPLOAD_ID --checksum-type FULL_OBJECT
