// React Native modules, which JavaScript actions import for the branches that
// run only on a phone. In the browser every member reads as another inert
// value, comparisons and awaits pass through, and calling one throws, so the
// web branches of the actions run untouched and a native-only call fails clearly.
const unavailable: unknown = new Proxy(function reactNativeModule() {}, {
  get(_target, property) {
    if (property === 'then') return undefined;
    if (property === Symbol.toPrimitive || property === 'toString' || property === 'valueOf')
      return () => 'React Native module (unavailable in the browser)';
    return unavailable;
  },
  apply() {
    throw new Error('React Native modules are not available in the browser');
  },
  construct() {
    throw new Error('React Native modules are not available in the browser');
  },
});

export default unavailable;
