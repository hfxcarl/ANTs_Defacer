#!/bin/bash

function Usage() {
	echo
	echo "Usage: $(basename $0) -i </path/to/t1.nii.gz> -t T1w"
	echo
	echo "Examples:" 
	echo "  $(basename $0) -t T1w -i /sub-01_T1w.nii.gz"
	echo "  $(basename $0) -t T2w -i /sub-01_T2w.nii.gz"
	echo
	echo "compulsory:"
	echo "  -i:  input image"
	echo "  -t:  image type [T1w, T2w, FLAIR]"
	echo
	echo "optional:"
	echo "  -v:  enable more verbose mode"
	echo "  -d:  enable debug mode to save work-dir, also enables -v"
	echo
	exit 1
}
function realpath { echo $(cd $(dirname $1); pwd)/$(basename $1); }

SCRIPT=$(realpath $0)
SCRIPTSDIR=$(dirname $SCRIPT)
project_dir=$SCRIPTSDIR

## ANTs
export ANTSPATH=/opt/ANTs/bin
export PATH="$ANTSPATH:$PATH"
export ITK_GLOBAL_DEFAULT_NUMBER_OF_THREADS=4

## FSL
export FSLDIR=/opt/fsl
source $FSLDIR/etc/fslconf/fsl.sh
export PATH="$PATH:$FSLDIR/bin"

## MNI Templates path for Defacing
MNI_T_PATH=$project_dir/templates
MNI_T1=${MNI_T_PATH}/MNI152_T1_1mm.nii.gz
MNI_T2=${MNI_T_PATH}/MNI152_T2_1mm.nii.gz
FACEMASK_SMALLFOV=${MNI_T_PATH}/MNI152_T1_1mm_facemask.nii.gz
FACEMASK_BIGFOV=${MNI_T_PATH}/MNI152_T1_1mm_BigFoV_facemask.nii.gz
FACEMASK=${FACEMASK_BIGFOV} #default to big, adjustable

[ "$#" -lt 4 ] && Usage


DSTR=$(date +%Y%m%d-%H%M)
VERBOSE="no"
DEBUG_MODE="no"
IMG_TYPE="T1w"			## options = ['T1', 'T2', 'FLAIR']
TemplateImg=${MNI_T1}	## assume T1w 

while [[ $# -gt 0 ]]; do
	key="$1"
	case $key in
		-t|--type)
			TYPE_IN="$2"
			shift
			shift 
			;;
		-i|--img)
			IN_IMG="$2"
			shift
			shift 
			;;
		-h|--help|--usage)
			Usage
			shift
			;;
		-d|--debug)
			DEBUG_MODE="yes"
			VERBOSE="yes"
			shift
			;;
		-v|--verbose)
			VERBOSE="yes"
			echo " -- enabling VERBOSE"
			shift
			;;
		*)  # unknown option
			echo " * found unknown input = \"$1\""
			shift 
			;;
	esac
done

## process COMPULSORY inputs
if [[ -z "$IN_IMG" ]]; then
	echo -e "\n * ERROR: missing input -i </path/to/img>\n"
	Usage
fi
input_img=$(realpath ${IN_IMG})
if [ ! -r "$input_img" ]; then
	echo "*** ERROR: cannot locate specified input_img = $input_img/"
	exit 2
fi
if [[ ! -z "$TYPE_IN" ]]; then
	if [ "$TYPE_IN" == "T1w" ]; then
		IMG_TYPE="T1w"
		TemplateImg=${MNI_T1}
	elif [ "$TYPE_IN" == "T2w" -o "$TYPE_IN" == "FLAIR" ]; then
		IMG_TYPE="T2w"
		TemplateImg=${MNI_T2}
	else
		echo " *** ERROR: processing input image type, found unknown option = \"${TYPE_IN}\""
		Usage
	fi
	echo " - input option IN_IMG=${IMG_TYPE}, using template=${TemplateImg}"
fi


if [ "$VERBOSE" == "yes" ]; then
	echo " ++ defacing $IMG_TYPE input image = $input_img"
fi

input_img_dir=$(dirname $input_img)
input_img_bn=$(basename $input_img)
img=$(basename ${input_img_bn} '.nii.gz') ## eg: "sub-01_ses-a1_T1w"
if [ -r "${input_img_dir}/${img}_defaced.nii.gz" ]; then
	echo " * defaced output found = ${input_img_dir}/${img}_defaced.nii.gz"
	exit 2
fi
cd $input_img_dir/


ST=$SECONDS
echo " + $(date +%Y%m%d-%H%M%S): runnning $(basename $0) on $input_img_bn"

## make work-dir next to input image
work_dir=$input_img_dir/${img}_defacing_work
mkdir -p $work_dir/
cd $work_dir/

if [ "$VERBOSE" == "yes" ]; then
	echo " ++ defacing anat=${img}.nii.gz in $(pwd)/"
fi
ln -sf ../${input_img_bn} ./${img}.nii.gz

## Do quick Bias Correction
if [ ! -r "${img}_n4.nii.gz" ]; then
	if [ "$VERBOSE" == "yes" ]; then
		echo " ++ bias-correcting input image ${img}.nii.gz --> ${img}_n4.nii.gz"
	fi
	${ANTSPATH}/N4BiasFieldCorrection -d 3 -i ${img}.nii.gz -o ${img}_n4.nii.gz -s 4 -b [200] -c [50x50x50x50,0.000001]
fi

## Do quick registration to MNI152 with ANTs
if [ ! -r "${img}_n4_2mni_0GenericAffine.mat" ]; then
	if [ "$VERBOSE" == "yes" ]; then
		echo " ++ running antsRegisistrationSyNQuick.sh ${img}_n4.nii.gz --> ${img}_n4_"
	fi
	${ANTSPATH}/antsRegistrationSyNQuick.sh -d 3 -f ${TemplateImg} -m ${img}_n4.nii.gz -o ${img}_n4_2mni_ -t s
fi

## Apply registration to move mask from MNI -> img
if [ ! -r "${img}_defacemask.nii.gz" ]; then
	let vflag=0
	if [ "$VERBOSE" == "yes" ]; then
		echo " ++ applying inverse affine+warp to FACEMASK ${FACEMASK} --> ${img}.nii.gz"
		let vflag=1
	fi
	${ANTSPATH}/antsApplyTransforms \
		--dimensionality 3 \
		--interpolation GenericLabel \
		--reference-image ${img}.nii.gz \
		--input $FACEMASK \
		--output ${img}_defacemask.nii.gz \
		--transform ${img}_n4_2mni_1InverseWarp.nii.gz \
		--transform [ ${img}_n4_2mni_0GenericAffine.mat , 1 ] \
		--verbose ${vflag}
fi

## Apply defacing mask to full image
if [ "$VERBOSE" == "yes" ]; then
	echo " ++ applying ${img}_defacemask.nii.gz to ${img}.nii.gz --> ${img}_defaced.nii.gz"
fi
fslmaths ${img}_defacemask.nii.gz -binv -mul ${img}.nii.gz ../${img}_defaced.nii.gz

## navigate back up to main output dir
cd ../
if [ "$DEBUG_MODE" == "yes" ]; then
	echo " * debug_mode enabled, not removing work-dir = ${work_dir}"
else
	rm -rfv $work_dir/
fi

echo " + $(date +%Y%m%d-%H%M%S): finished ants defacing $(basename $0) on ${input_img_bn} in $(($SECONDS - $ST)) secs"
ls -l ./


exit 0
