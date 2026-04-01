#!/bin/bash

# Where do we store the fragments
# by default store in current directory
BACKUP_FILE=`realpath $1`
BACKUP_FILENAME=`basename $BACKUP_FILE`
BUCKET_NAME=liams-computer-backup
FRAGMENT_COUNT=200
# Get the CRC32 of the file
CRC=`crc32 $BACKUP_FILE`


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
	split -n $PART_NUMBER/$FRAGMENT_COUNT --numeric-suffixes=1 $BACKUP_FILE > $BACKUP_FILE.$PART_NUMBER
	part=$BACKUP_FILE.$PART_NUMBER
	PART_CRC32=`crc32 $part | xxd -r -p | base64`
	ETAG=($(md5sum $part))
	FILE_PARTS=`echo $FILE_PARTS | jq --argjson part_number $PART_NUMBER --arg part_crc32 "$PART_CRC32" --arg etag "${ETAG}" '.Parts += [{"PartNumber":$part_number, ETag:$etag, ChecksumCRC32:$part_crc32}]'`
	aws s3api upload-part --bucket $BUCKET_NAME --key $BACKUP_FILENAME --part-number $PART_NUMBER --body $BACKUP_FILE.$PART_NUMBER --upload-id $UPLOAD_ID --checksum-algorithm CRC32
	rm $BACKUP_FILE.$PART_NUMBER
	((PART_NUMBER++))
done

## Complete the upload
echo $FILE_PARTS > fileparts.json
aws s3api complete-multipart-upload --multipart-upload file://fileparts.json --bucket $BUCKET_NAME --key $BACKUP_FILENAME --upload-id $UPLOAD_ID --checksum-type FULL_OBJECT
