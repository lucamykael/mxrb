import { describe, expect, it } from 'vitest';
import { customChartLayout, customChartSpec } from './plotly';

describe('native CustomChart JSON semantics', () => {
  it('concatenates static and dynamic traces and uses sample values only for empty dynamic inputs', () => {
    const properties = {
      dataStatic: '[{"name":"Static"}]', dataAttribute: {attribute: 'App.Owner.Data'},
      sampleData: '[{"name":"Sample"}]', layoutStatic: '{"title":"Static","xaxis":{"type":"log"}}',
      layoutAttribute: 'Layout', sampleLayout: '{"title":"Sample"}', configurationOptions: '{"scrollZoom":true}',
    };
    const context = {id: 'owner', type: 'App.Owner', attributes: {Data: '[{"name":"Dynamic"}]', Layout: '{"title":"Dynamic"}'}};
    expect(customChartSpec(properties, context)).toEqual({
      data: [{name: 'Static'}, {name: 'Dynamic'}], layout: {title: 'Dynamic', xaxis: {type: 'log'}},
      config: {displayModeBar: false, scrollZoom: true},
    });
    expect(customChartSpec(properties, null)).toEqual({
      data: [{name: 'Static'}, {name: 'Sample'}], layout: {title: 'Sample', xaxis: {type: 'log'}},
      config: {displayModeBar: false, scrollZoom: true},
    });
  });
  it('preserves explicit nested Plotly options and native sizing defaults', () => {
    const layout = customChartLayout({legend: {font: {color: 'red'}}, margin: {l: 20}, xaxis: {type: 'log'}}, 800, 400);
    expect(layout).toMatchObject({width: 800, height: 400, autosize: true, font: {size: expect.closeTo(9.6)},
      legend: {font: {color: 'red'}, itemwidth: 8}, xaxis: {type: 'log', tickfont: {size: 8}},
      margin: {l: 20, r: 60, t: 60, b: 60, pad: 10}});
  });
  it.each([{dataStatic: '{}'}, {dataStatic: '[null]'}, {layoutStatic: '[]'}, {configurationOptions: 'false'}])(
    'reports malformed configuration %j', properties => {
      expect(() => customChartSpec(properties, null)).toThrow();
    },
  );
});
