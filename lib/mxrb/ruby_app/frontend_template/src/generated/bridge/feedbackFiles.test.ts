import { afterEach, describe, expect, it, vi } from 'vitest';
import { decimal } from './decimal';
import {
  recalculateModalErrorZindex,
  revokeUploadedFileFromMemory,
  uploadAndConvertToFileBlobURL,
} from './feedbackFiles';
import { feedbackStorageActions } from './feedbackStorage';

const megabytes = (size: number, type = 'image/png') =>
  new File([new Uint8Array(Math.round(size * 1024 * 1024))], 'a.png', { type });

function upload(file: File | null, mimeTypes: string | null, size: unknown = decimal('5')) {
  const result = uploadAndConvertToFileBlobURL(
    { userDefined_mimeTypes: mimeTypes, userDefined_fileUploadSize: size } as never,
    {},
  );
  const input = document.querySelector<HTMLInputElement>('#fileupload')!;
  if (file) {
    Object.defineProperty(input, 'files', { value: [file] });
    input.onchange!(new Event('change'));
  } else {
    input.dispatchEvent(new Event('cancel'));
  }
  return { result, input };
}

afterEach(() => {
  document.body.innerHTML = '';
  vi.restoreAllMocks();
  vi.useRealTimers();
});

describe('Feedback image upload actions', () => {
  it('opens a hidden single-file input and resolves the module status texts', async () => {
    vi.spyOn(URL, 'createObjectURL').mockReturnValue('blob:http://localhost/1');
    const click = vi.spyOn(HTMLInputElement.prototype, 'click').mockImplementation(() => undefined);
    const accepted = upload(megabytes(1), 'image/png,image/jpeg');
    expect(click).toHaveBeenCalled();
    expect(accepted.input.accept).toBe('image/png,image/jpeg');
    expect(accepted.input.style.left).toBe('-9999px');
    expect(await accepted.result).toBe('blob:http://localhost/1');
    expect(document.querySelector('#fileupload, .mx-progress')).toBeNull();
    expect(await upload(megabytes(1, 'text/plain'), 'image/.*').result).toBe('fileTypeNotAccepted');
    expect(await upload(megabytes(1, 'text/plain'), null).result).toBe('blob:http://localhost/1');
    const cancelled = upload(null, null);
    expect(await cancelled.result).toBe('uploadCancelled');
    expect(document.body.contains(cancelled.input)).toBe(true);
  });

  it('limits the size by the first significant digit plus 0.1 MB', async () => {
    vi.spyOn(URL, 'createObjectURL').mockReturnValue('');
    vi.spyOn(HTMLInputElement.prototype, 'click').mockImplementation(() => undefined);
    expect(await upload(megabytes(2.05), 'image/png', decimal('25')).result).toBe('fileNotConverted');
    expect(await upload(megabytes(2.2), 'image/png', decimal('25')).result).toBe('fileSizeNotAccepted');
    expect(await upload(megabytes(0.05), 'image/png', 0).result).toBe('fileNotConverted');
    expect(await upload(megabytes(0.3), 'image/png', decimal('0.25')).result).toBe('fileNotConverted');
    expect(await upload(megabytes(0.2), 'image/png', decimal('0.001')).result).toBe('fileNotConverted');
  });

  it('revokes blob URLs and raises message dialogs after half a second', async () => {
    const revoke = vi.spyOn(URL, 'revokeObjectURL').mockImplementation(() => undefined);
    await revokeUploadedFileFromMemory({ fileBlobURL: 'blob:x' }, {});
    expect(revoke).toHaveBeenCalledWith('blob:x');
    await expect(revokeUploadedFileFromMemory({ fileBlobURL: null }, {})).rejects.toThrow(
      'Image was not removed from browser memory',
    );
    vi.useFakeTimers();
    document.body.innerHTML =
      '<div class="mx-dialog-error"></div><div class="mx-dialog-warning"></div><div class="mx-underlay"></div>';
    await recalculateModalErrorZindex({}, {});
    expect(document.querySelector<HTMLElement>('.mx-dialog-error')!.style.zIndex).toBe('');
    vi.advanceTimersByTime(500);
    expect(document.querySelector<HTMLElement>('.mx-dialog-error')!.style.zIndex).toBe('90');
    expect(document.querySelector<HTMLElement>('.mx-dialog-warning')!.style.zIndex).toBe('');
    expect(document.querySelector<HTMLElement>('.mx-underlay')!.style.zIndex).toBe('80');
  });

  it('is registered with the Feedback module actions', () => {
    expect(Object.keys(feedbackStorageActions(['JS_UploadAndConvertToFileBlobURL']))).toEqual([
      'FeedbackModule.JS_UploadAndConvertToFileBlobURL',
    ]);
  });
});
