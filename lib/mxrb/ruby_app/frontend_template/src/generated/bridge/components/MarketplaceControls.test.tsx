import { fireEvent, render, screen } from '@testing-library/react';
import { describe, expect, it, vi } from 'vitest';
import {
  MarketplaceWidget,
  registerMarketplaceWidget,
  type MarketplaceWidgetProps,
} from '../marketplace';
import { ReadOnlyContext } from './FieldPolicy';
import type { ApplicationSchema } from '../../types';

const props = (kind: string, properties: Record<string, unknown> = {}): MarketplaceWidgetProps => ({
  widget: {
    type: 'pluggable_widget',
    name: 'Control',
    options: { widget_id: `com.mendix.widget.native.${kind.toLowerCase()}.${kind}`, properties },
  },
  context: {
    id: '1',
    type: 'App.Item',
    attributes: { Lower: 15, Upper: 80, Rating: 2, Color: '#123456', Amount: 40 },
  },
  onChange: vi.fn(),
});

describe('Marketplace controls use source properties and runtime data', () => {
  it('executes an application-owned adapter for the exact widget identity', () => {
    const input = props('External', { caption: 'Edited adapter' });
    const restore = registerMarketplaceWidget(
      String(input.widget.options?.widget_id),
      ({ widget, onClick }) => (
        <button onClick={onClick}>{String(widget.options?.properties?.caption)}</button>
      ),
    );
    input.onClick = vi.fn();
    try {
      render(<MarketplaceWidget {...input} />);
      fireEvent.click(screen.getByRole('button', { name: 'Edited adapter' }));
      expect(input.onClick).toHaveBeenCalledOnce();
    } finally {
      restore();
    }
  });

  it('renders the exported static image resource and invokes its click action', () => {
    const input = props('Image', {
      datasource: 'image',
      imageObject: 'App.Images.Logo',
      alternativeText: 'Logo',
      width: 50,
      widthUnit: 'percentage',
    });
    input.schema = {
      presentation: { 'App.Images.Logo': { kind: 'image', path: '/assets/logo.png' } },
    } as unknown as ApplicationSchema;
    input.onClick = vi.fn();
    render(<MarketplaceWidget {...input} />);
    expect(screen.getByRole('img', { name: 'Logo' })).toHaveAttribute('src', '/assets/logo.png');
    expect(screen.getByRole('img')).toHaveStyle({ width: '50%' });
    fireEvent.click(screen.getByRole('button'));
    expect(input.onClick).toHaveBeenCalledOnce();
  });

  it('resolves dynamic URLs while rejecting unsafe schemes', () => {
    const input = props('Image', { imageUrl: '$currentObject/URL', alternativeText: 'Dynamic' });
    input.context!.attributes.URL = 'https://example.test/image.png';
    const { rerender } = render(<MarketplaceWidget {...input} />);
    expect(screen.getByRole('img')).toHaveAttribute('src', 'https://example.test/image.png');
    input.context!.attributes.URL = 'javascript:alert(1)';
    rerender(<MarketplaceWidget {...input} />);
    expect(screen.queryByRole('img')).not.toBeInTheDocument();
    expect(screen.getByRole('status')).toHaveTextContent('Invalid image URL');
  });

  it('uses both bound range attributes, limits and step, instead of a local dummy value', () => {
    const input = props('RangeSlider', {
      lowerValueAttribute: 'App.Item.Lower',
      upperValueAttribute: 'App.Item.Upper',
      minimumValue: '10',
      maximumValue: '90',
      stepSize: '5',
    });
    render(<MarketplaceWidget {...input} />);
    const lower = screen.getByRole('slider', { name: 'Control minimum' });
    const upper = screen.getByRole('slider', { name: 'Control maximum' });
    expect(lower).toHaveValue('15');
    expect(upper).toHaveValue('80');
    expect(lower).toHaveAttribute('max', '80');
    expect(upper).toHaveAttribute('min', '15');
    expect(lower).toHaveAttribute('step', '5');
    fireEvent.change(upper, { target: { value: '85' } });
    expect(input.onChange).toHaveBeenCalledWith('App.Item.Upper', 85);
  });

  it('respects inherited read-only policies and later source data updates', () => {
    const input = props('Slider', { valueAttribute: 'App.Item.Amount' });
    const { rerender } = render(
      <ReadOnlyContext value={true}>
        <MarketplaceWidget {...input} />
      </ReadOnlyContext>,
    );
    expect(screen.getByRole('slider')).toBeDisabled();
    expect(screen.getByRole('slider')).toHaveValue('40');
    input.context!.attributes.Amount = 70;
    rerender(<MarketplaceWidget {...input} />);
    expect(screen.getByRole('slider')).toBeEnabled();
    expect(screen.getByRole('slider')).toHaveValue('70');
  });

  it('evaluates progress expressions and honors a nonzero minimum', () => {
    render(
      <MarketplaceWidget
        {...props('ProgressBar', {
          progressValue: '$currentObject/Amount',
          minimumValue: '10',
          maximumValue: '90',
        })}
      />,
    );
    expect(screen.getByRole('progressbar')).toHaveAttribute('value', '30');
    expect(screen.getByRole('progressbar')).toHaveAttribute('max', '80');
  });

  it('writes color and rating values to their declared attributes', () => {
    const color = props('ColorPicker', { color: 'App.Item.Color' });
    const { rerender } = render(<MarketplaceWidget {...color} />);
    fireEvent.change(screen.getByLabelText('Control'), { target: { value: '#abcdef' } });
    expect(color.onChange).toHaveBeenCalledWith('App.Item.Color', '#abcdef');
    const rating = props('Rating', { ratingAttribute: 'App.Item.Rating', maximumValue: 3 });
    rerender(<MarketplaceWidget {...rating} />);
    expect(screen.getAllByRole('button')).toHaveLength(3);
    fireEvent.click(screen.getByRole('button', { name: '3 stars' }));
    expect(rating.onChange).toHaveBeenCalledWith('App.Item.Rating', 3);
  });

  it('supports the legacy StarRating attribute binding', () => {
    const input = props('StarRating', { rateAttribute: 'App.Item.Rating' });
    render(<MarketplaceWidget {...input} />);
    expect(screen.getByRole('button', { name: '2 stars' })).toHaveAttribute('aria-pressed', 'true');
    expect(screen.getByRole('button', { name: '3 stars' })).toHaveAttribute(
      'aria-pressed',
      'false',
    );
    fireEvent.click(screen.getByRole('button', { name: '4 stars' }));
    expect(input.onChange).toHaveBeenCalledWith('App.Item.Rating', 4);
  });

  it('uses declared enumeration captions and updates the bound value', () => {
    const input = props('ToggleButtons', { enum: 'App.Item.State' });
    input.context!.attributes.State = 'Draft';
    input.schema = {
      modules: [
        {
          models: [{ name: 'App.Item', attributes: [{ name: 'State', enumeration: 'App.State' }] }],
          enumerations: [
            {
              name: 'App.State',
              values: [
                { name: 'Draft', caption: 'Draft caption' },
                { name: 'Ready', caption: 'Ready caption' },
              ],
            },
          ],
        },
      ],
    } as unknown as ApplicationSchema;
    render(<MarketplaceWidget {...input} />);
    expect(screen.getByRole('button', { name: 'Draft caption' })).toHaveAttribute(
      'aria-pressed',
      'true',
    );
    fireEvent.click(screen.getByRole('button', { name: 'Ready caption' }));
    expect(input.onChange).toHaveBeenCalledWith('App.Item.State', 'Ready');
  });
});
