const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const copyInstall = $('#copy-install');
copyInstall.hidden = false;
copyInstall.addEventListener('click', async () => {
  const command = $('#install-command');
  const status = $('#copy-status');
  try {
    await navigator.clipboard.writeText(command.textContent);
    status.textContent = 'Copied. Paste into Terminal to install.';
  } catch {
    const selection = window.getSelection();
    const range = document.createRange();
    range.selectNodeContents(command);
    selection.removeAllRanges();
    selection.addRange(range);
    status.textContent = 'Copy the selected command, then paste it into Terminal.';
  }
});
const widget = $('#custom-widget');
const preview = $('#desktop-preview');
let uploadUrl;
let refreshTimer;
let refreshCount = 0;
const sampleReadings = [12, 18, 9, 24, 16, 11];
const initialOrder = ['cpu', 'custom', 'battery', 'clock'];
const sprites = [
  { name: 'Peek', x: 160, y: 310 },
  { name: 'Bitwing', x: 460, y: 300 },
  { name: 'Droplet', x: 774, y: 312 },
  { name: 'Mochi', x: 1072, y: 328 },
  { name: 'Comet', x: 1381, y: 311 },
  { name: 'Bud', x: 160, y: 720 },
  { name: 'Batlet', x: 464, y: 736 },
  { name: 'Tilekin', x: 772, y: 725 },
  { name: 'Orbit', x: 1077, y: 735 },
  { name: 'Fold', x: 1371, y: 719 }
];
function showMessage(message) {
  $('#upload-message').textContent = message;
  $('#upload-message').hidden = !message;
}
function clearImage() {
  if (uploadUrl) URL.revokeObjectURL(uploadUrl);
  uploadUrl = undefined;
  $('#custom-image').hidden = true;
  $('#custom-image').removeAttribute('src');
  widget.querySelector('.menu-sprite-art')?.remove();
  $$('.sprite-choice').forEach(button => button.setAttribute('aria-pressed', 'false'));
}
function setIcon(name) {
  clearImage();
  $('#widget-icon').toggleAttribute('hidden', name === 'none');
  $('#widget-icon use').setAttribute('href', `#icon-${name}`);
  $('#image-control').value = '';
  showMessage('');
}
function setColor(color) {
  preview.style.setProperty('--widget-color', color);
  $('#color-control').value = color;
  $$('.swatch').forEach(button => {
    const selected = button.dataset.color.toLowerCase() === color.toLowerCase();
    button.classList.toggle('selected', selected);
    button.setAttribute('aria-pressed', String(selected));
  });
}
function startRefresh() {
  clearInterval(refreshTimer);
  refreshTimer = undefined;
  const interval = Number($('#refresh-control').value);
  const status = $('#refresh-status');
  if (!interval) { status.textContent = 'Updates paused.'; return; }
  status.textContent = `Example CPU updates every ${interval / 1000}s.`;
  if (document.hidden) return;
  refreshTimer = setInterval(() => {
    if (!$('[data-item="cpu"]').hidden) {
      refreshCount += 1;
      $('#cpu-value').textContent = `${sampleReadings[refreshCount % sampleReadings.length]}%`;
    }
  }, interval);
}
$('#label-control').addEventListener('input', event => { $('#widget-label').textContent = event.target.value; });
$('#icon-control').addEventListener('change', event => setIcon(event.target.value));
$('#weight-control').addEventListener('change', event => { widget.style.fontWeight = event.target.value; });
$('#style-control').addEventListener('change', event => {
  widget.style.fontStyle = event.target.value === 'italic' ? 'italic' : 'normal';
  widget.style.fontFamily = event.target.value === 'monospace' ? 'ui-monospace, monospace' : 'system-ui, sans-serif';
});
$('#size-control').addEventListener('input', event => {
  preview.style.setProperty('--widget-size', `${event.target.value}px`);
  $('#size-output').textContent = `${event.target.value} px`;
});
$('#refresh-control').addEventListener('change', startRefresh);
document.addEventListener('visibilitychange', startRefresh);
$('#color-control').addEventListener('input', event => setColor(event.target.value));
$$('.swatch').forEach(button => button.addEventListener('click', () => setColor(button.dataset.color)));
$('#motion-control').addEventListener('change', event => {
  widget.classList.toggle('is-animated', event.target.checked);
  if (event.target.checked && matchMedia('(prefers-reduced-motion: reduce)').matches) {
    showMessage('Your reduced-motion preference keeps this preview still.');
  } else { showMessage(''); }
});
$$('[data-toggle]').forEach(button => button.addEventListener('click', () => {
  const pressed = button.getAttribute('aria-pressed') !== 'true';
  button.setAttribute('aria-pressed', String(pressed));
  $(`[data-item="${button.dataset.toggle}"]`).hidden = !pressed;
}));
$('#move-widget').addEventListener('click', () => {
  const items = $('#menu-items');
  const previous = widget.previousElementSibling;
  if (previous) items.insertBefore(widget, previous); else items.append(widget);
});
$('#image-control').addEventListener('change', event => {
  const file = event.target.files[0];
  if (!file) return;
  if (!['image/png', 'image/jpeg', 'image/webp', 'image/gif', 'image/svg+xml'].includes(file.type) || file.size > 5 * 1024 * 1024) {
    showMessage('Choose a PNG, JPEG, WebP, GIF, or SVG under 5 MB.');
    event.target.value = ''; return;
  }
  clearImage();
  uploadUrl = URL.createObjectURL(file);
  const image = $('#custom-image');
  image.onload = () => { image.hidden = false; $('#widget-icon').setAttribute('hidden', ''); showMessage('Your image stays in this tab. Nothing is uploaded.'); };
  image.onerror = () => { clearImage(); $('#widget-icon').removeAttribute('hidden'); showMessage('That image could not be opened. Try another file.'); };
  image.src = uploadUrl;
});
function spriteArt(sprite, small = false) {
  const frame = document.createElement('span');
  frame.className = small ? 'menu-sprite-art' : 'sprite-art';
  frame.setAttribute('aria-hidden', 'true');
  const image = document.createElement('img');
  const scale = small ? 0.088 : 0.42;
  image.src = '/assets/sprite-library.png';
  image.alt = '';
  image.loading = small ? 'eager' : 'lazy';
  image.style.width = `${1536 * scale}px`;
  image.style.height = `${1024 * scale}px`;
  image.style.left = `calc(50% - ${sprite.x * scale}px)`;
  image.style.top = `calc(50% - ${sprite.y * scale}px)`;
  frame.append(image);
  return frame;
}
sprites.forEach(sprite => {
  const button = document.createElement('button');
  button.type = 'button'; button.className = 'sprite-choice';
  button.setAttribute('aria-pressed', 'false');
  button.setAttribute('aria-label', `Use ${sprite.name} sprite in the preview`);
  button.append(spriteArt(sprite));
  const name = document.createElement('span'); name.textContent = sprite.name; button.append(name);
  button.addEventListener('click', () => {
    clearImage();
    $('#widget-icon').setAttribute('hidden', '');
    widget.prepend(spriteArt(sprite, true));
    button.setAttribute('aria-pressed', 'true');
    $('[data-item="custom"]').hidden = false;
    $('[data-toggle="custom"]').setAttribute('aria-pressed', 'true');
    $('#label-control').value = sprite.name;
    $('#widget-label').textContent = sprite.name;
    showMessage(`${sprite.name} is in your preview. You can still change its label and style.`);
  });
  $('#sprite-gallery').append(button);
});
$('#reset-demo').addEventListener('click', () => {
  clearImage();
  $('#label-control').value = 'Deep work'; $('#widget-label').textContent = 'Deep work';
  $('#icon-control').value = 'moon'; setIcon('moon');
  $('#weight-control').value = '600'; widget.style.fontWeight = '600';
  $('#style-control').value = 'normal'; widget.style.fontStyle = 'normal'; widget.style.fontFamily = 'system-ui, sans-serif';
  $('#size-control').value = '14'; preview.style.setProperty('--widget-size', '14px'); $('#size-output').textContent = '14 px';
  setColor('#7652e7'); $('#motion-control').checked = false; widget.classList.remove('is-animated');
  $('#refresh-control').value = '0'; startRefresh(); refreshCount = 0; $('#cpu-value').textContent = '12%';
  initialOrder.forEach(item => { const node = $(`[data-item="${item}"]`); node.hidden = false; $('#menu-items').append(node); });
  $$('[data-toggle]').forEach(button => button.setAttribute('aria-pressed', 'true'));
  showMessage('');
});
window.addEventListener('pagehide', () => { clearInterval(refreshTimer); if (uploadUrl) URL.revokeObjectURL(uploadUrl); });
