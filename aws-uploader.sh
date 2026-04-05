#!/bin/bash

if [ $# -ne 1 ]; then
	echo "Usage: ./aws-uploader.sh <filename>"
	exit 1
fi

BACKUP_FILE=`realpath $1`
BACKUP_FILENAME=`basename $BACKUP_FILE`
BUCKET_NAME=liams-computer-backup
FRAGMENT_COUNT=200

wait_availability () {
	while [ ! "$(dig +short amazonaws.com)" ]; do
		echo "waiting for connection"
		sleep 10s
		wait_availability
	done
	read < $BACKUP_FILE 2> /dev/null
	if [ $? -ne 0 ]; then
		echo "file not available"
		sleep 10s
		wait_availability
	fi
}

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

FILE_PARTS="{
	\"Parts\": []
}" 
# Upload each part individually
PART_NUMBER=1
while [ $PART_NUMBER -lt $FRAGMENT_COUNT ]; do
	wait_availability 	

	# extract the right chunk
	split -n $PART_NUMBER/$FRAGMENT_COUNT --numeric-suffixes=1 --verbose $BACKUP_FILE > $BACKUP_FILE.$PART_NUMBER
	part=$BACKUP_FILE.$PART_NUMBER
	# check for prior uploads
	PRIOR_UPLOAD=`echo $UPLOADED_PARTS | jq --argjson part_number $PART_NUMBER '.Parts.[] | select(.PartNumber == $part_number)'`
	if [ ! -z "$PRIOR_UPLOAD" ] ; then
		echo "Checking $PART_NUMBER"
		PART_CRC32=`crc32 $part | xxd -r -p | base64`
		CRC_MATCHES=`echo $PRIOR_UPLOAD | jq --arg part_crc $PART_CRC32 '.ChecksumCRC32 == $part_crc'`
		if [ "$CRC_MATCHES" == "false" ] ; then
			echo "Checksum mismatch with uploaded part $PRIOR_UPLOAD expected $PART_CRC32. Reuploading..."
		else
			# remove the old part
			rm $part
			((PART_NUMBER++))
			continue
			
		fi 
	fi
	# save attributes for completing the upload
	ETAG=($(md5sum $part))
	FILE_PARTS=`echo $FILE_PARTS | jq --argjson part_number $PART_NUMBER --arg part_crc32 "$PART_CRC32" --arg etag "${ETAG}" '.Parts += [{"PartNumber":$part_number, ETag:$etag, ChecksumCRC32:$part_crc32}]'`
 	# upload the part
	aws s3api upload-part --bucket $BUCKET_NAME --key $BACKUP_FILENAME --part-number $PART_NUMBER --body $BACKUP_FILE.$PART_NUMBER --upload-id $UPLOAD_ID --checksum-algorithm CRC32
	# remove the old part
	rm $part
	((PART_NUMBER++))
done


# Complete the upload
echo $FILE_PARTS > fileparts.json
aws s3api complete-multipart-upload --multipart-upload file://fileparts.json --bucket $BUCKET_NAME --key $BACKUP_FILENAME --upload-id $UPLOAD_ID --checksum-type FULL_OBJECT
