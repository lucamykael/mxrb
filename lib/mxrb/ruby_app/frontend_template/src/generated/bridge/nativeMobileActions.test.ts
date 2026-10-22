import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  nativeMobileActions,
  setPicturePicker,
  subscribeNotifications,
  type NativeNotification,
} from './nativeMobileActions';
import { decimal } from './decimal';
import type { EntityRecord } from '../types';

const actions = nativeMobileActions([
  'BiometricAuthentication',
  'IsBiometricAuthenticationSupported',
  'CancelAllScheduledNotifications',
  'CancelScheduledNotification',
  'ClearAllDeliveredNotifications',
  'ChangeStatusBar',
  'CheckGenericPermission',
  'RequestGenericPermission',
  'DisplayNotification',
  'ScheduleNotification',
  'DownloadFile',
  'GetClipboardContent',
  'SetClipboardContent',
  'GetDeviceInfo',
  'GetPushNotificationToken',
  'HasNotificationPermission',
  'RequestNotificationPermission',
  'HideKeyboard',
  'IsConnected',
  'IsWifiConnection',
  'IsCellularConnection',
  'OpenInAppBrowser',
  'ParseUrlToObject',
  'PlaySound',
  'RegisterDeepLink',
  'SaveToPictureLibrary',
  'SetBadgeNumber',
  'TakePicture',
  'TakePictureAdvanced',
  'Vibrate',
]);
const call = (name: string, parameters: Record<string, unknown> = {}) =>
  actions[`NativeMobileResources.${name}`](parameters as never);
const file: EntityRecord = {
  id: '7',
  type: 'System.FileDocument',
  attributes: { Name: 'song.mp3' },
};

class FakeNotification {
  static permission: NotificationPermission = 'granted';
  static instances: FakeNotification[] = [];
  static requestPermission = vi.fn(async () => 'granted' as NotificationPermission);
  onclick: (() => void) | null = null;
  onclose: (() => void) | null = null;
  close = vi.fn(() => this.onclose?.());
  constructor(
    public title: string,
    public options: NotificationOptions,
  ) {
    FakeNotification.instances.push(this);
  }
}

describe('Native Mobile Resources browser adapters', () => {
  beforeEach(() => {
    FakeNotification.instances = [];
    FakeNotification.permission = 'granted';
    vi.stubGlobal('Notification', FakeNotification);
  });
  afterEach(() => {
    vi.unstubAllGlobals();
    vi.restoreAllMocks();
    vi.useRealTimers();
  });

  it('registers only known actions under the module namespace', () => {
    expect(Object.keys(nativeMobileActions(['Vibrate']))).toEqual([
      'NativeMobileResources.Vibrate',
    ]);
    expect(() => nativeMobileActions(['Teleport'])).toThrow(
      'Unknown Native Mobile Resources action: Teleport',
    );
  });

  it('vibrates, reads the connection and hides the keyboard through the navigator', async () => {
    const vibrate = vi.fn();
    Object.defineProperty(navigator, 'vibrate', { value: vibrate, configurable: true });
    await call('Vibrate', {});
    await call('Vibrate', { duration: 250 });
    expect(vibrate.mock.calls).toEqual([[500], [250]]);
    Object.defineProperty(navigator, 'onLine', { value: false, configurable: true });
    expect(await call('IsConnected')).toBe(false);
    Object.defineProperty(navigator, 'connection', { value: { type: 'wifi' }, configurable: true });
    expect(await call('IsWifiConnection')).toBe(true);
    expect(await call('IsCellularConnection')).toBe(false);
    const input = document.createElement('input');
    document.body.appendChild(input);
    input.focus();
    expect(document.activeElement).toBe(input);
    await call('HideKeyboard');
    expect(document.activeElement).not.toBe(input);
    input.remove();
  });

  it('uses the clipboard, the app badge, the in-app browser and the theme colour', async () => {
    const clipboard = {
      readText: vi.fn(async () => 'copied'),
      writeText: vi.fn(async () => undefined),
    };
    Object.defineProperty(navigator, 'clipboard', { value: clipboard, configurable: true });
    expect(await call('GetClipboardContent')).toBe('copied');
    await call('SetClipboardContent', { content: 'text' });
    expect(clipboard.writeText).toHaveBeenCalledWith('text');
    await expect(call('SetClipboardContent', { content: '' })).rejects.toThrow(
      "Input parameter 'Content' is required",
    );
    const setAppBadge = vi.fn(async () => undefined);
    Object.defineProperty(navigator, 'setAppBadge', { value: setAppBadge, configurable: true });
    await call('SetBadgeNumber', { badgeNumber: 3 });
    expect(setAppBadge).toHaveBeenCalledWith(3);
    await expect(call('SetBadgeNumber', { badgeNumber: 0 })).rejects.toThrow('is required');
    await expect(call('SetBadgeNumber', { badgeNumber: -1 })).rejects.toThrow('zero or greater');
    const open = vi.spyOn(window, 'open').mockReturnValue(null);
    await call('OpenInAppBrowser', { url: 'https://example.test/' });
    expect(open).toHaveBeenCalledWith('https://example.test/', '_blank', 'noopener');
    await expect(call('OpenInAppBrowser', { url: '' })).rejects.toThrow(
      "Input parameter 'url' is required",
    );
    await call('ChangeStatusBar', { backgroundColor: '#123456', hidden: true });
    expect(document.querySelector('meta[name="theme-color"]')).toHaveAttribute(
      'content',
      '#123456',
    );
  });

  it('downloads, plays and saves file documents through the file API', async () => {
    const click = vi
      .spyOn(HTMLAnchorElement.prototype, 'click')
      .mockImplementation(() => undefined);
    await call('DownloadFile', { file });
    expect(click).toHaveBeenCalledOnce();
    const open = vi.spyOn(window, 'open').mockReturnValue(null);
    await call('DownloadFile', { file, openWithOS: true });
    expect(open).toHaveBeenCalledWith('/api/files/System.FileDocument/7', '_blank', 'noopener');
    expect(await call('SaveToPictureLibrary', { picture: file })).toBe(
      '/api/files/System.FileDocument/7?download=1',
    );
    await expect(call('DownloadFile', { file: null })).rejects.toThrow(
      "Input parameter 'file' is required",
    );
    await expect(call('PlaySound', { audioFile: 'song' })).rejects.toThrow('must be an object');
    const play = vi.spyOn(HTMLMediaElement.prototype, 'play').mockImplementation(function (
      this: HTMLMediaElement,
    ) {
      this.onended?.(new Event('ended'));
      return Promise.resolve();
    });
    await call('PlaySound', { audioFile: file });
    expect(play).toHaveBeenCalledOnce();
  });

  it('parses a URL into the attributes the entity declares and describes the device', async () => {
    const record = (await call('ParseUrlToObject', {
      uRL: 'https://john:secret@www.example.com:123/forum/questions/?tag=networking&Order=newest#top',
      entity: 'App.Link',
    })) as EntityRecord;
    expect(record.type).toBe('App.Link');
    expect(record.transient).toBe(true);
    expect(record.attributes).toMatchObject({
      protocol: 'https:',
      hash: 'top',
      query: '?tag=networking&Order=newest',
      pathname: '/forum/questions/',
      auth: 'john:secret',
      host: 'www.example.com:123',
      port: '123',
      hostname: 'www.example.com',
      username: 'john',
      path0: 'forum',
      path1: 'questions',
      tag: 'networking',
      order: 'newest',
    });
    await expect(call('ParseUrlToObject', { uRL: '', entity: 'App.Link' })).rejects.toThrow(
      'is required',
    );
    const info = (await call('GetDeviceInfo')) as EntityRecord;
    expect(info.type).toBe('NativeMobileResources.DeviceInfo');
    expect(info.attributes.UserAgent).toBe(navigator.userAgent);
    expect(info.attributes.Timezone).toBe(Intl.DateTimeFormat().resolvedOptions().timeZone);
    expect(info.attributes.BatteryLevel).toEqual(decimal('1'));
  });

  it('displays and schedules notifications the Notifications widget receives', async () => {
    vi.useFakeTimers();
    const received: Array<[string, NativeNotification]> = [];
    const unsubscribe = subscribeNotifications((event, notification) =>
      received.push([event, notification]),
    );
    await call('DisplayNotification', {
      body: 'Hello',
      title: 'Hi',
      actionName: 'Open',
      actionGuid: '9',
    });
    expect(received).toEqual([
      [
        'receive',
        expect.objectContaining({
          body: 'Hello',
          title: 'Hi',
          actionName: 'Open',
          actionGuid: '9',
        }),
      ],
    ]);
    expect(FakeNotification.instances).toHaveLength(1);
    FakeNotification.instances[0].onclick?.();
    expect(received[1][0]).toBe('open');
    await expect(call('DisplayNotification', { body: '' })).rejects.toThrow(
      "Input parameter 'Body' is required",
    );

    const date = new Date(Date.now() + 60_000).toISOString();
    await call('ScheduleNotification', { date, body: 'Later', notificationId: 'later' });
    await call('ScheduleNotification', { date, body: 'Cancelled', notificationId: 'gone' });
    await call('CancelScheduledNotification', { notificationId: 'gone' });
    vi.advanceTimersByTime(60_000);
    expect(received.filter(([event]) => event === 'receive').map(([, item]) => item.body)).toEqual([
      'Hello',
      'Later',
    ]);
    await expect(call('ScheduleNotification', { date: 'soon', body: 'x' })).rejects.toThrow(
      'valid Date',
    );
    await call('ScheduleNotification', { date, body: 'All' });
    await call('CancelAllScheduledNotifications');
    vi.advanceTimersByTime(60_000);
    expect(received.map(([, item]) => item.body)).not.toContain('All');
    await call('ClearAllDeliveredNotifications');
    expect(FakeNotification.instances[0].close).toHaveBeenCalled();
    unsubscribe();
  });

  it('answers permissions with the browser APIs that exist', async () => {
    expect(await call('HasNotificationPermission')).toBe(true);
    expect(await call('RequestNotificationPermission')).toBe(true);
    expect(await call('CheckGenericPermission', { permission: 'POST_NOTIFICATIONS_ANDROID' })).toBe(
      'granted',
    );
    expect(await call('CheckGenericPermission', { permission: 'BLUETOOTH_PERIPHERAL_IOS' })).toBe(
      'unavailable',
    );
    FakeNotification.permission = 'default';
    expect(
      await call('RequestGenericPermission', { permission: 'POST_NOTIFICATIONS_ANDROID' }),
    ).toBe('granted');
    Object.defineProperty(navigator, 'permissions', {
      value: { query: vi.fn(async () => ({ state: 'denied' })) },
      configurable: true,
    });
    expect(await call('CheckGenericPermission', { permission: 'CAMERA_IOS' })).toBe('blocked');
    await expect(call('CheckGenericPermission', { permission: '' })).rejects.toThrow('is required');
    vi.spyOn(window, 'confirm').mockReturnValue(true);
    expect(await call('BiometricAuthentication', { reason: 'Sign' })).toBe(true);
    expect(window.confirm).toHaveBeenCalledWith('Sign');
    expect(await call('IsBiometricAuthenticationSupported')).toBe(false);
    await expect(call('GetPushNotificationToken')).rejects.toThrow('not available in the browser');
    await expect(call('RegisterDeepLink', { urlHandler: '' })).rejects.toThrow(
      'URL handler nanoflow',
    );
    const handler = vi.fn();
    await call('RegisterDeepLink', { urlHandler: handler });
    expect(handler).toHaveBeenCalledWith({ URL: window.location.href });
  });

  it('stores a taken picture in the image object and reports the file', async () => {
    const picture: EntityRecord = { id: '4', type: 'App.Photo', attributes: {} };
    const fetchMock = vi.fn(async () => new Response('{}', { status: 200 }));
    vi.stubGlobal('fetch', fetchMock);
    setPicturePicker(async () => new File(['data'], 'shot.png', { type: 'image/png' }));
    expect(
      await call('TakePicture', { picture, pictureSource: 'camera', pictureQuality: 'original' }),
    ).toBe(true);
    expect(fetchMock).toHaveBeenCalledOnce();
    const [url, options] = fetchMock.mock.calls[0] as unknown as [string, RequestInit];
    expect(url).toBe('/api/files/App.Photo/4');
    expect(options.method).toBe('PUT');
    expect(JSON.parse(String(options.body))).toEqual({ name: 'shot.png', content: btoa('data') });
    expect(picture.attributes.Name).toBe('shot.png');
    const metadata = (await call('TakePictureAdvanced', { picture })) as EntityRecord;
    expect(metadata.type).toBe('NativeMobileResources.ImageMetaData');
    expect(metadata.attributes).toMatchObject({
      PictureTaken: true,
      FileName: 'shot.png',
      FileSize: 4,
      FileType: 'image/png',
    });
    setPicturePicker(async () => undefined);
    expect(await call('TakePicture', { picture })).toBe(false);
    await expect(call('TakePicture', { picture, pictureQuality: 'custom' })).rejects.toThrow(
      'no maximum width or height',
    );
    await expect(call('TakePicture', { picture: null })).rejects.toThrow(
      "Input parameter 'Picture' is required",
    );
  });
});
