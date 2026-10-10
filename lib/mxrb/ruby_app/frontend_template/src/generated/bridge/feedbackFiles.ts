import type { RuntimeValue } from '../types';
import type { JavaScriptAction } from './nanoflow';
import { decimalNumber } from './decimal';

// The Feedback module's image upload helpers, ported from the verified sources:
// a hidden file input resolves a blob URL or one of the module's status texts.
// A cancelled dialog leaves its input in the page, as the module does.

const showProgress = (): HTMLElement => {
  const progress = document.createElement('div');
  progress.className = 'mx-progress';
  document.body.appendChild(progress);
  return progress;
};

function finish(fileInput: HTMLInputElement, progress: HTMLElement | undefined): void {
  progress?.remove();
  fileInput.remove();
}

// Each comma-separated accepted type is a regular expression tested against the
// MIME type, so an empty accept list admits everything.
const acceptedType = (accepted: string, fileType: string): boolean =>
  !(!accepted && !fileType) && accepted.split(',').some((type) => new RegExp(type).test(fileType));

// The module compares megabytes with the first digit of the big.js coefficient
// (maxSize.c[0]) plus 0.1, so 25 allows 2.1 MB.
function firstDigit(value: RuntimeValue | undefined): number {
  const digits = decimalNumber(value).abs().toFixed().replace('.', '').replace(/^0+/, '');
  return Number(digits[0] ?? 0);
}

const acceptedSize = (file: File, maxSize: RuntimeValue | undefined): boolean =>
  file.size / 1024 / 1024 < firstDigit(maxSize) + 0.1;

export const uploadAndConvertToFileBlobURL: JavaScriptAction = (parameters) =>
  new Promise((resolve) => {
    const mimeTypes = parameters.userDefined_mimeTypes;
    const fileInput = document.createElement('input');
    fileInput.style.position = 'absolute';
    fileInput.style.left = '-9999px';
    fileInput.name = 'fileupload';
    fileInput.id = 'fileupload';
    fileInput.type = 'file';
    if (mimeTypes) fileInput.accept = String(mimeTypes);
    fileInput.multiple = false;
    fileInput.onchange = () => {
      const file = fileInput.files![0];
      const progress = showProgress();
      if (!acceptedType(fileInput.accept, file.type)) {
        finish(fileInput, progress);
        return resolve('fileTypeNotAccepted');
      }
      if (!acceptedSize(file, parameters.userDefined_fileUploadSize)) {
        finish(fileInput, progress);
        return resolve('fileSizeNotAccepted');
      }
      const url = URL.createObjectURL(file);
      finish(fileInput, progress);
      resolve(url && typeof url === 'string' ? url : 'fileNotConverted');
    };
    document.body.appendChild(fileInput);
    fileInput.addEventListener('cancel', () => resolve('uploadCancelled'));
    fileInput.click();
  });

export const revokeUploadedFileFromMemory: JavaScriptAction = async ({ fileBlobURL }) => {
  if (!fileBlobURL || typeof fileBlobURL !== 'string')
    throw new Error('Image was not removed from browser memory');
  URL.revokeObjectURL(fileBlobURL);
};

// Raises Mendix message dialogs above the Feedback modal half a second later. The
// warning selector lacks its dot in the module and therefore never matches.
export const recalculateModalErrorZindex: JavaScriptAction = async () => {
  const setZindex = (selector: string, zIndex: string) =>
    document.querySelectorAll<HTMLElement>(selector).forEach((item) => {
      item.style.zIndex = zIndex;
    });
  setTimeout(() => {
    setZindex('.mx-dialog-info, mx-dialog-warning, .mx-dialog-error', '90');
    setZindex('.mx-underlay', '80');
  }, 500);
};
