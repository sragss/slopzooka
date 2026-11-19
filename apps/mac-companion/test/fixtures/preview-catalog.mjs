// Only replace the native screen inventory in the two-companion routing test.
import { WindowPreviews } from '../../src/window-previews.ts';
WindowPreviews.prototype.catalog = async () => ({
  state: 'ready',
  sources: [{ id: 'window:fixture', title: 'Private fixture title', application: 'Fixture', contentWidth: 100, contentHeight: 100 }],
});
