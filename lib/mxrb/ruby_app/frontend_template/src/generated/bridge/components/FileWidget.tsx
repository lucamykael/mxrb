import { useContext, useEffect, useState } from 'react';
import type { WidgetRuntimeProps } from '../contracts';
import { editable, ReadOnlyContext } from './FieldPolicy';
import { presentationFrame } from './PresentationWidgets';
import { DataView } from './WidgetRenderer';

const encodedFile = (file: File): Promise<string> =>
  new Promise((resolve, reject) => {
    const reader = new FileReader();
    reader.onerror = () => reject(reader.error || new Error('Unable to read file'));
    reader.onload = () => resolve(String(reader.result).split(',', 2)[1] || '');
    reader.readAsDataURL(file);
  });

export function FileWidget(props: WidgetRuntimeProps) {
  const source = props.widget.options?.source;
  if (source)
    return (
      <DataView
        {...props}
        renderRecord={(record) => (
          <FileContentWidget {...props} context={record} pageContext={record} />
        )}
      />
    );
  return <FileContentWidget {...props} />;
}

function FileContentWidget(props: WidgetRuntimeProps) {
  const { widget, context, pageContext, revision, request, onError, onMutation } = props;
  const options = widget.options || {};
  const record = context || pageContext;
  const inheritedReadOnly = useContext(ReadOnlyContext);
  const [busy, setBusy] = useState(false);
  const [version, setVersion] = useState(0);
  const [name, setName] = useState('Download file');
  const [missing, setMissing] = useState(false);
  const path = record
    ? `/api/files/${encodeURIComponent(record.type)}/${encodeURIComponent(record.id)}`
    : '';
  useEffect(() => {
    setMissing(false);
    setName('Download file');
  }, [path, revision]);
  const isImage = widget.type !== 'file_manager';
  const viewer = widget.type === 'image_viewer';
  const disabled = !record || busy || inheritedReadOnly || !editable(options, record);
  const mode = String(options.mode || 'both').toLowerCase();
  const extensions = String(options.allowed_extensions || '')
    .split(/[;,\s]+/)
    .filter(Boolean)
    .map((value) => `.${value.replace(/^\*?\.?/, '').toLowerCase()}`);
  const accept = extensions.length
    ? extensions.join(',')
    : isImage
      ? 'image/png,image/jpeg,image/gif,image/webp'
      : undefined;
  const defaultImage = props.schema.presentation?.[String(options.default_image || '')]?.path;
  const thumbnail = options.show_as_thumbnail
    ? `&thumbnail_width=${Number(options.thumbnail_width || 100)}&thumbnail_height=${Number(options.thumbnail_height || 75)}`
    : '';
  const image = !record || missing ? defaultImage : `${path}?v=${revision}-${version}${thumbnail}`;
  return (
    <div {...presentationFrame(props)} aria-busy={busy}>
      {isImage && image && (
        <img
          src={image}
          alt={String(options.alternative_text || options.caption || widget.name)}
          onError={() => setMissing(true)}
          style={{
            maxWidth: options.responsive !== false ? '100%' : undefined,
            width:
              options.width_unit === 'auto'
                ? undefined
                : `${Number(options.width || options.thumbnail_width || 100)}${options.width_unit === 'percentage' ? '%' : 'px'}`,
            height:
              options.height_unit === 'auto'
                ? undefined
                : `${Number(options.height || options.thumbnail_height || 75)}${options.height_unit === 'percentage' ? '%' : 'px'}`,
            objectFit: options.show_as_thumbnail ? 'contain' : undefined,
          }}
        />
      )}
      {!viewer && mode !== 'download' && (
        <label>
          {String(options.caption || widget.name)}
          <input
            type="file"
            disabled={disabled}
            accept={accept}
            onChange={(event) => {
              const file = event.target.files?.[0];
              event.target.value = '';
              if (!file || disabled) return;
              const limit = Math.min(Number(options.max_file_size || 5), 20) * 1024 * 1024;
              if (file.size > limit) {
                onError(new Error(`File exceeds ${limit / 1024 / 1024} MiB`));
                return;
              }
              if (
                extensions.length &&
                !extensions.some((extension) => file.name.toLowerCase().endsWith(extension))
              ) {
                onError(new Error('File extension is not allowed'));
                return;
              }
              if (
                isImage &&
                !['image/png', 'image/jpeg', 'image/gif', 'image/webp'].includes(file.type)
              ) {
                onError(new Error('Select a PNG, JPEG, GIF or WebP image'));
                return;
              }
              setBusy(true);
              void encodedFile(file)
                .then((content) =>
                  request(path, {
                    method: 'PUT',
                    body: JSON.stringify({ name: file.name, content }),
                  }),
                )
                .then(() => {
                  setName(file.name);
                  setMissing(false);
                  setVersion((value) => value + 1);
                  onMutation();
                })
                .catch(onError)
                .finally(() => setBusy(false));
            }}
          />
        </label>
      )}
      {record && !isImage && mode !== 'upload' && <a href={`${path}?download=1`}>{name}</a>}
      {record && viewer && options.on_click_enlarge === true && (
        <a href={path} target="_blank" rel="noreferrer">
          Open image
        </a>
      )}
      {missing && !defaultImage && viewer && <span role="status">No image available</span>}
    </div>
  );
}
