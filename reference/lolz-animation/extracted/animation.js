/*
 * Minimal source-derived extraction of the menu's MmenuLight off-canvas
 * setup and the XenForo.MobileMenu click binding. See README.md for original
 * bundle URLs and the source locations. This file is for reference only.
 */
(() => {
	const menu = document.querySelector('#menu');
	const trigger = document.querySelector('.mobileMenuButton > a#nav-icon4[href="#menu"]');

	if (!menu || !trigger) return;

	const wrapper = document.createElement('div');
	wrapper.classList.add('mm-ocd', 'mm-ocd--left');

	const content = document.createElement('div');
	content.classList.add('mm-ocd__content');
	wrapper.append(content);

	const backdrop = document.createElement('div');
	backdrop.classList.add('mm-ocd__backdrop');
	wrapper.append(backdrop);
	document.body.append(wrapper);

	content.append(menu);

	function close(event) {
		wrapper.classList.remove('mm-ocd--open');
		document.body.classList.remove('mm-ocd-opened');
		event.stopImmediatePropagation();
	}

	function open(event) {
		wrapper.classList.add('mm-ocd--open');
		document.body.classList.add('mm-ocd-opened');
		event.preventDefault();
		event.stopPropagation();
	}

	backdrop.addEventListener('touchstart', close, { passive: true });
	backdrop.addEventListener('mousedown', close, { passive: true });
	trigger.classList.add('no-scroll');
	trigger.addEventListener('click', open);
})();
