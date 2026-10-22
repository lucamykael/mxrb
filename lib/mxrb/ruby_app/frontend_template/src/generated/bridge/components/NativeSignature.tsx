// The native signature pad: strokes drawn with the pointer on a canvas, saved
// as a PNG into the image object of the context, with the widget's actions.
import { useRef, useState } from 'react';
import { useCaptionEnvironment, chartCaption } from '../captions';
import type { MarketplaceWidgetProps } from '../marketplace';
import { marketplaceAction } from './marketplaceData';

type Properties = Record<string, unknown>;

export function NativeSignature(props: MarketplaceWidgetProps) {
  const environment = useCaptionEnvironment(props.schema);
  const properties = (props.widget.options?.properties || {}) as Properties;
  const canvas = useRef<HTMLCanvasElement>(null);
  const drawing = useRef(false);
  const [signed, setSigned] = useState(false);
  const [busy, setBusy] = useState(false);
  const run = (value: unknown) => {
    const action = marketplaceAction(value);
    return action ? props.onAction?.(action, props.context) : undefined;
  };
  const point = (event: React.PointerEvent<HTMLCanvasElement>) => {
    const bounds = event.currentTarget.getBoundingClientRect();
    return {
      x: ((event.clientX - bounds.left) / (bounds.width || 1)) * event.currentTarget.width,
      y: ((event.clientY - bounds.top) / (bounds.height || 1)) * event.currentTarget.height,
    };
  };
  const context = () => canvas.current?.getContext('2d') ?? null;
  const clear = () => {
    const element = canvas.current;
    const surface = context();
    if (element && surface) surface.clearRect(0, 0, element.width, element.height);
    setSigned(false);
    void run(properties.onClear);
  };
  const save = async () => {
    const element = canvas.current;
    if (!element || !signed) {
      void run(properties.onEmpty);
      return;
    }
    if (!props.context || !props.request)
      throw new Error('Signature needs an image object to save into');
    const content = element.toDataURL('image/png').split(',', 2)[1] || '';
    setBusy(true);
    try {
      await props.request(
        `/api/files/${encodeURIComponent(props.context.type)}/${encodeURIComponent(props.context.id)}`,
        { method: 'PUT', body: JSON.stringify({ name: 'signature.png', content }) },
      );
      await run(properties.onSignEndAction ?? properties.onEnd);
    } finally {
      setBusy(false);
    }
  };
  return (
    <div className="mxrb-native-signature" data-image-source={String(properties.imageSource || '')}>
      <canvas
        ref={canvas}
        width={600}
        height={300}
        role="img"
        aria-label={props.widget.name}
        className="mxrb-native-signature__pad"
        onPointerDown={(event) => {
          const surface = context();
          if (!surface) return;
          const { x, y } = point(event);
          surface.lineWidth = 3;
          surface.lineCap = 'round';
          surface.strokeStyle = '#000';
          surface.beginPath();
          surface.moveTo(x, y);
          drawing.current = true;
          event.currentTarget.setPointerCapture?.(event.pointerId);
        }}
        onPointerMove={(event) => {
          const surface = context();
          if (!drawing.current || !surface) return;
          const { x, y } = point(event);
          surface.lineTo(x, y);
          surface.stroke();
          setSigned(true);
        }}
        onPointerUp={() => {
          drawing.current = false;
        }}
      />
      <div className="mxrb-native-signature__buttons">
        <button type="button" className="btn btn-default" disabled={busy} onClick={clear}>
          {chartCaption(properties.buttonCaptionClear, props.context, environment) || 'Clear'}
        </button>
        <button
          type="button"
          className="btn btn-primary"
          disabled={busy}
          onClick={() => void save()}
        >
          {chartCaption(properties.buttonCaptionSave, props.context, environment) || 'Save'}
        </button>
      </div>
    </div>
  );
}
