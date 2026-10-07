(async () => {
  const waitFor = async (check: () => boolean) => {
    for (let i = 0; i < 160; i += 1) {
      if (check()) return;
      await new Promise(resolve => setTimeout(resolve, 50));
    }
    throw new Error('Native storage scenario timed out');
  };
  const click = (name: string) => {
    const button = document.querySelector<HTMLButtonElement>(`.mx-name-${name}`);
    if (!button) throw new Error(`Missing button ${name}`);
    button.click();
  };
  const message = async (text: string) => {
    await waitFor(() => [...document.querySelectorAll('.modal-dialog')].some(node => node.textContent?.includes(text)));
    const button = document.querySelector<HTMLButtonElement>('.modal-dialog button.btn-primary');
    if (!button) throw new Error('Missing message confirmation');
    button.click();
    await waitFor(() => document.querySelector('.modal-dialog') === null);
  };
  localStorage.removeItem('mxrb-feedback-oracle');
  click('ReadLegacy'); await message('Legacy: []');
  click('ReadBoolean'); await message('true');
  click('WriteImage'); await message('stored');
  const stored = JSON.parse(localStorage.getItem('mxrb-feedback-oracle') || 'null');
  if (stored?.ImageB64 !== 'synthetic-image') throw new Error('Stored image differs');
  click('ReadImage'); await message('synthetic-image');
  click('ReadLegacy'); await message('Legacy: [synthetic-image]');
  localStorage.setItem('mxrb-feedback-oracle', JSON.stringify({...stored, ShowEmail: false}));
  click('ReadBoolean'); await message('false');
  return {status:'passed', image:stored.ImageB64, boolean_fallback:true, stored_boolean:false,
    legacy_missing:'', legacy_image:'synthetic-image'};
})();
