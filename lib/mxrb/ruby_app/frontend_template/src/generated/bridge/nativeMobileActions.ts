// Browser adapters for the JavaScript actions of Native Mobile Resources. Their
// React Native implementation (notifee, netinfo, image picker, clipboard,
// vibration, biometrics, ...) is replaced by the web platform API that covers
// the same contract; the parameters keep the names of the Mendix actions.
import { api } from './api';
import { decimal } from './decimal';
import type { JavaScriptAction } from './nanoflow';
import { expressionSchema } from './schemaLookup';
import { isEntityRecord } from './value';
import type { EntityRecord, RuntimeValue } from '../types';

// A notification the application displayed or scheduled; the Notifications
// widget receives it when it shows and when the user opens it.
export interface NativeNotification {
  id: string;
  body: string;
  title?: string;
  subtitle?: string;
  actionName?: string;
  actionGuid?: string;
}

export type NotificationEvent = 'receive' | 'open';
type NotificationListener = (event: NotificationEvent, notification: NativeNotification) => void;

const listeners = new Set<NotificationListener>();
const scheduled = new Map<string, number>();
const delivered = new Set<Notification>();

export function subscribeNotifications(listener: NotificationListener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

const notify = (event: NotificationEvent, notification: NativeNotification) =>
  listeners.forEach((listener) => listener(event, notification));

const text = (value: RuntimeValue | undefined): string =>
  value === null || value === undefined ? '' : String(value);

const required = (value: RuntimeValue | undefined, name: string): string => {
  if (!value) throw new Error(`Input parameter '${name}' is required`);
  return String(value);
};

const requiredRecord = (value: RuntimeValue | undefined, name: string): EntityRecord => {
  if (!value) throw new Error(`Input parameter '${name}' is required`);
  if (!isEntityRecord(value)) throw new TypeError(`Input parameter '${name}' must be an object`);
  return value;
};

const fileUrl = (record: EntityRecord, download = false) =>
  `/api/files/${encodeURIComponent(record.type)}/${encodeURIComponent(record.id)}${download ? '?download=1' : ''}`;

const transient = (type: string, attributes: Record<string, RuntimeValue>): EntityRecord => ({
  id: crypto.randomUUID(),
  type,
  attributes,
  transient: true,
});

const numberOf = (value: RuntimeValue | undefined): number => {
  const raw =
    value && typeof value === 'object' && '__mxrb_decimal' in value
      ? (value as { __mxrb_decimal: string }).__mxrb_decimal
      : value;
  const parsed = Number(raw);
  return Number.isFinite(parsed) ? parsed : 0;
};

function showNotification(notification: NativeNotification, playSound: boolean) {
  notify('receive', notification);
  if (typeof Notification === 'undefined' || Notification.permission !== 'granted') return;
  const shown = new Notification(notification.title || document.title, {
    body: notification.body,
    tag: notification.id,
    silent: !playSound,
  });
  shown.onclick = () => {
    shown.close();
    notify('open', notification);
  };
  shown.onclose = () => delivered.delete(shown);
  delivered.add(shown);
}

const notificationOf = (
  parameters: Record<string, RuntimeValue | undefined>,
  id: string,
): NativeNotification => ({
  id,
  body: required(parameters.body, 'Body'),
  title: text(parameters.title) || undefined,
  subtitle: text(parameters.subtitle) || undefined,
  actionName: text(parameters.actionName) || undefined,
  actionGuid: text(parameters.actionGuid) || undefined,
});

// The browser permission that stands in for a React Native permission name.
type PermissionState = 'unavailable' | 'denied' | 'limited' | 'granted' | 'blocked';
const webPermission = (
  name: string,
): 'camera' | 'microphone' | 'geolocation' | 'notifications' | undefined => {
  if (/CAMERA/.test(name)) return 'camera';
  if (/MICROPHONE|RECORD_AUDIO/.test(name)) return 'microphone';
  if (/LOCATION/.test(name)) return 'geolocation';
  if (/NOTIFICATION/.test(name)) return 'notifications';
  return undefined;
};

async function checkPermission(name: string): Promise<PermissionState> {
  const permission = webPermission(name);
  if (!permission) return 'unavailable';
  if (permission === 'notifications')
    return typeof Notification === 'undefined'
      ? 'unavailable'
      : Notification.permission === 'granted'
        ? 'granted'
        : Notification.permission === 'denied'
          ? 'blocked'
          : 'denied';
  if (!navigator.permissions) return 'unavailable';
  try {
    const status = await navigator.permissions.query({ name: permission as PermissionName });
    return status.state === 'granted'
      ? 'granted'
      : status.state === 'denied'
        ? 'blocked'
        : 'denied';
  } catch {
    return 'unavailable';
  }
}

async function requestPermission(name: string): Promise<PermissionState> {
  const current = await checkPermission(name);
  if (current !== 'denied') return current;
  const permission = webPermission(name);
  try {
    if (permission === 'notifications')
      return (await Notification.requestPermission()) === 'granted' ? 'granted' : 'blocked';
    if (permission === 'geolocation') {
      await new Promise<void>((resolve, reject) =>
        navigator.geolocation.getCurrentPosition(() => resolve(), reject),
      );
      return 'granted';
    }
    const stream = await navigator.mediaDevices.getUserMedia(
      permission === 'camera' ? { video: true } : { audio: true },
    );
    stream.getTracks().forEach((track) => track.stop());
    return 'granted';
  } catch {
    return 'blocked';
  }
}

// Lets the user pick or take a picture; tests replace it, as the browser
// cannot open the file dialog without a user gesture.
export type PicturePicker = (source: string) => Promise<File | undefined>;
let picturePicker: PicturePicker = (source) =>
  new Promise((resolve) => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = 'image/*';
    if (source === 'camera') input.setAttribute('capture', 'environment');
    input.onchange = () => resolve(input.files?.[0]);
    input.oncancel = () => resolve(undefined);
    input.click();
  });
export const setPicturePicker = (picker: PicturePicker) => {
  picturePicker = picker;
};

const qualityLimit = (
  quality: string,
  maximumWidth: RuntimeValue | undefined,
  maximumHeight: RuntimeValue | undefined,
): number => {
  if (quality === 'original') return 0;
  if (quality === 'low') return 1024;
  if (quality === 'high') return 4096;
  if (quality === 'custom') return Math.max(numberOf(maximumWidth), numberOf(maximumHeight));
  return 2048;
};

// The picture scaled within the quality's maximum dimension, as a base64 PNG.
async function scaled(file: File, limit: number): Promise<{ content: string; type: string }> {
  const encode = (blob: Blob) =>
    new Promise<string>((resolve, reject) => {
      const reader = new FileReader();
      reader.onerror = () => reject(reader.error || new Error('Unable to read picture'));
      reader.onload = () => resolve(String(reader.result).split(',', 2)[1] || '');
      reader.readAsDataURL(blob);
    });
  if (!limit || typeof createImageBitmap !== 'function')
    return { content: await encode(file), type: file.type };
  const bitmap = await createImageBitmap(file);
  const scale = Math.min(1, limit / Math.max(bitmap.width, bitmap.height));
  if (scale === 1) return { content: await encode(file), type: file.type };
  const canvas = document.createElement('canvas');
  canvas.width = Math.round(bitmap.width * scale);
  canvas.height = Math.round(bitmap.height * scale);
  canvas.getContext('2d')?.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  const blob = await new Promise<Blob | null>((resolve) => canvas.toBlob(resolve, 'image/png'));
  if (!blob) throw new Error('Unable to scale picture');
  return { content: await encode(blob), type: 'image/png' };
}

async function takePicture(
  parameters: Record<string, RuntimeValue | undefined>,
): Promise<{ file: File; type: string } | undefined> {
  const picture = requiredRecord(parameters.picture, 'Picture');
  const quality = text(parameters.pictureQuality);
  if (quality === 'custom' && !parameters.maximumHeight && !parameters.maximumWidth)
    throw new Error(
      "Picture quality is set to 'Custom', but no maximum width or height was provided",
    );
  const file = await picturePicker(text(parameters.pictureSource));
  if (!file) return undefined;
  const image = await scaled(
    file,
    qualityLimit(quality, parameters.maximumWidth, parameters.maximumHeight),
  );
  await api(fileUrl(picture), {
    method: 'PUT',
    body: JSON.stringify({ name: file.name, content: image.content }),
  });
  picture.attributes.Name = file.name;
  return { file, type: image.type };
}

const download = (url: string, name: string) => {
  const anchor = document.createElement('a');
  anchor.href = url;
  anchor.download = name;
  anchor.rel = 'noopener';
  document.body.appendChild(anchor);
  anchor.click();
  anchor.remove();
};

type Connection = { type?: string };
const connection = (): Connection =>
  (navigator as Navigator & { connection?: Connection }).connection || {};

// Device information the browser exposes, in the DeviceInfo entity of the module.
async function deviceInfo(): Promise<EntityRecord> {
  const battery = await (navigator as Navigator & { getBattery?: () => Promise<{ level: number }> })
    .getBattery?.()
    .then((status) => status.level)
    .catch(() => undefined);
  const memory = (navigator as Navigator & { deviceMemory?: number }).deviceMemory;
  const data = (
    navigator as Navigator & { userAgentData?: { platform?: string; mobile?: boolean } }
  ).userAgentData;
  const tablet =
    /ipad|tablet/i.test(navigator.userAgent) || Boolean(data?.mobile && window.innerWidth >= 600);
  const hourCycle = new Intl.DateTimeFormat(navigator.language, {
    hour: 'numeric',
  }).resolvedOptions().hourCycle;
  return transient('NativeMobileResources.DeviceInfo', {
    ApplicationName: document.title,
    BatteryLevel: decimal((battery ?? 1).toFixed(2)),
    Brand: navigator.vendor || '',
    BuildNumber: '',
    BundleId: window.location.origin,
    Carrier: '',
    DeviceCountry: (navigator.language.split('-')[1] || '').toUpperCase(),
    DeviceId: data?.platform || navigator.platform,
    DeviceLocale: navigator.language,
    FontScale: decimal('1.00'),
    FreeDiskStorage: decimal('0'),
    Manufacturer: navigator.vendor || '',
    Model: data?.platform || navigator.platform,
    ReadableVersion: navigator.appVersion,
    SystemName: data?.platform || navigator.platform,
    SystemVersion: navigator.appVersion,
    Timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    TotalDiskCapacity: decimal('0'),
    TotalMemory: decimal(String(memory ? memory * 1024 * 1024 * 1024 : 0)),
    UniqueId: '',
    UserAgent: navigator.userAgent,
    Version: navigator.appVersion,
    Is24Hour: hourCycle === 'h23' || hourCycle === 'h24',
    IsEmulator: false,
    IsTablet: tablet,
    IsLandscape: window.innerWidth > window.innerHeight,
    HasNotch: false,
  });
}

// The parts of a URL as ParseUrlToObject names them: the URL fields, path0..n
// and every query key, set on the attributes the entity declares.
function parsedUrl(url: string, entity: string): EntityRecord {
  const parsed = new URL(url);
  const values: Record<string, string> = {
    protocol: parsed.protocol,
    hash: parsed.hash.replace(/^#/, ''),
    query: parsed.search,
    pathname: parsed.pathname,
    auth: parsed.username
      ? `${parsed.username}${parsed.password ? `:${parsed.password}` : ''}`
      : '',
    host: parsed.host,
    port: parsed.port,
    hostname: parsed.hostname,
    password: parsed.password,
    username: parsed.username,
    origin: parsed.origin,
    href: parsed.href,
  };
  parsed.pathname
    .replace(/^\/*/, '')
    .split('/')
    .forEach((part, index) => {
      values[`path${index}`] = part;
    });
  parsed.searchParams.forEach((value, key) => {
    values[key.toLowerCase()] = value;
  });
  const schema = expressionSchema();
  const declared = schema?.modules
    .flatMap((module) => [...(module.models || []), ...(module.dtos || [])])
    .find((model) => model.name === entity)
    ?.attributes?.map((attribute) => attribute.name);
  const names = declared ?? Object.keys(values);
  const attributes = Object.fromEntries(
    names.flatMap((name) => {
      const value = values[name.toLowerCase()];
      return value ? [[name, value]] : [];
    }),
  );
  return transient(entity, attributes);
}

const handlers: Record<string, JavaScriptAction> = {
  BiometricAuthentication: async ({ reason }) =>
    window.confirm(text(reason) || 'Verify your identity to continue'),
  IsBiometricAuthenticationSupported: async () => {
    try {
      return (
        (await PublicKeyCredential?.isUserVerifyingPlatformAuthenticatorAvailable?.()) === true
      );
    } catch {
      return false;
    }
  },
  CancelAllScheduledNotifications: async () => {
    scheduled.forEach((timer) => window.clearTimeout(timer));
    scheduled.clear();
  },
  CancelScheduledNotification: async ({ notificationId }) => {
    const id = required(notificationId, 'Notification id');
    const timer = scheduled.get(id);
    if (timer !== undefined) window.clearTimeout(timer);
    scheduled.delete(id);
  },
  ClearAllDeliveredNotifications: async () => {
    delivered.forEach((notification) => notification.close());
    delivered.clear();
  },
  ChangeStatusBar: async ({ backgroundColor }) => {
    const color = text(backgroundColor);
    if (!color) return;
    let meta = document.querySelector<HTMLMetaElement>('meta[name="theme-color"]');
    if (!meta) {
      meta = document.createElement('meta');
      meta.name = 'theme-color';
      document.head.appendChild(meta);
    }
    meta.content = color;
  },
  CheckGenericPermission: async ({ permission }) =>
    checkPermission(required(permission, 'permission')),
  RequestGenericPermission: async ({ permission }) =>
    requestPermission(required(permission, 'permission')),
  DisplayNotification: async (parameters) => {
    showNotification(
      notificationOf(parameters, crypto.randomUUID()),
      parameters.playSound === true,
    );
  },
  ScheduleNotification: async (parameters) => {
    const notification = notificationOf(
      parameters,
      text(parameters.notificationId) || crypto.randomUUID(),
    );
    const date = new Date(text(parameters.date));
    if (!parameters.date || Number.isNaN(date.getTime()))
      throw new Error("Input parameter 'Date' is required and must be a valid Date object");
    const previous = scheduled.get(notification.id);
    if (previous !== undefined) window.clearTimeout(previous);
    scheduled.set(
      notification.id,
      window.setTimeout(
        () => {
          scheduled.delete(notification.id);
          showNotification(notification, parameters.playSound === true);
        },
        Math.max(0, date.getTime() - Date.now()),
      ),
    );
  },
  DownloadFile: async ({ file, openWithOS }) => {
    const record = requiredRecord(file, 'file');
    if (openWithOS === true) window.open(fileUrl(record), '_blank', 'noopener');
    else download(fileUrl(record, true), text(record.attributes.Name) || 'file');
  },
  GetClipboardContent: async () => navigator.clipboard.readText(),
  SetClipboardContent: async ({ content }) => {
    await navigator.clipboard.writeText(required(content, 'Content'));
  },
  GetDeviceInfo: deviceInfo,
  GetPushNotificationToken: async () => {
    throw new Error('Push notification tokens are not available in the browser');
  },
  HasNotificationPermission: async () =>
    typeof Notification !== 'undefined' && Notification.permission === 'granted',
  RequestNotificationPermission: async () => {
    if (typeof Notification === 'undefined') return false;
    return (await Notification.requestPermission()) === 'granted';
  },
  HideKeyboard: async () => {
    const active = document.activeElement;
    if (active instanceof HTMLElement) active.blur();
  },
  IsConnected: async () => navigator.onLine,
  IsWifiConnection: async () => connection().type === 'wifi',
  IsCellularConnection: async () => connection().type === 'cellular',
  OpenInAppBrowser: async ({ url }) => {
    window.open(required(url, 'url'), '_blank', 'noopener');
  },
  ParseUrlToObject: async ({ uRL, entity }) =>
    parsedUrl(required(uRL, 'uRL'), required(entity, 'entity')),
  PlaySound: async ({ audioFile }) => {
    const record = requiredRecord(audioFile, 'Audio file');
    await new Promise<void>((resolve, reject) => {
      const audio = new Audio(fileUrl(record));
      audio.onended = () => resolve();
      audio.onerror = () =>
        reject(new Error(`Failed to load audio: ${text(record.attributes.Name)}`));
      audio.play().catch(reject);
    });
  },
  RegisterDeepLink: async ({ urlHandler }) => {
    const handler = urlHandler as unknown;
    if (typeof handler !== 'function')
      throw new Error('RegisterDeepLink needs a URL handler nanoflow the browser runtime can call');
    const handle = (url: string) => (handler as (value: { URL: string }) => unknown)({ URL: url });
    await handle(window.location.href);
    window.addEventListener('hashchange', () => void handle(window.location.href));
  },
  SaveToPictureLibrary: async ({ picture }) => {
    const record = requiredRecord(picture, 'Picture');
    const url = fileUrl(record, true);
    download(url, text(record.attributes.Name) || 'picture');
    return url;
  },
  SetBadgeNumber: async ({ badgeNumber }) => {
    if (!badgeNumber) throw new Error("Input parameter 'Badge number' is required");
    const count = numberOf(badgeNumber);
    if (count < 0) throw new Error("Input parameter 'Badge number' should be zero or greater");
    await (
      navigator as Navigator & { setAppBadge?: (count: number) => Promise<void> }
    ).setAppBadge?.(count);
  },
  TakePicture: async (parameters) => Boolean(await takePicture(parameters)),
  TakePictureAdvanced: async (parameters) => {
    const taken = await takePicture(parameters);
    return transient('NativeMobileResources.ImageMetaData', {
      PictureTaken: Boolean(taken),
      URI: taken ? fileUrl(parameters.picture as EntityRecord) : '',
      FileName: taken?.file.name ?? '',
      FileSize: taken?.file.size ?? 0,
      FileType: taken?.type ?? '',
    });
  },
  Vibrate: async ({ duration }) => {
    navigator.vibrate?.(numberOf(duration) || 500);
  },
};

export const nativeMobileActions = (names: string[]): Record<string, JavaScriptAction> =>
  Object.fromEntries(
    names.map((name) => {
      const action = handlers[name];
      if (!action) throw new Error(`Unknown Native Mobile Resources action: ${name}`);
      return [`NativeMobileResources.${name}`, action];
    }),
  );
