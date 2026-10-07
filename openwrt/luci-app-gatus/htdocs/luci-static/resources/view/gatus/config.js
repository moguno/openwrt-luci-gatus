'use strict';
'require view';
'require fs';
'require ui';

var CONFIG_PATH = '/etc/gatus/config.yaml';

function currentValue() {
	var ta = document.querySelector('#gatus-config');
	return (ta && 'value' in ta) ? ta.value : '';
}

return view.extend({
	load: function() {
		return L.resolveDefault(fs.read(CONFIG_PATH), '');
	},

	render: function(content) {
		return E('div', { 'class': 'cbi-map' }, [
			E('h2', {}, _('Gatus')),
			E('div', { 'class': 'cbi-map-descr' }, [
				_('Edit the Gatus configuration file directly:'), ' ',
				E('code', {}, CONFIG_PATH)
			]),
			E('div', { 'class': 'cbi-section' }, [
				E('textarea', {
					'id': 'gatus-config',
					'class': 'cbi-input-textarea',
					'rows': 40,
					'wrap': 'off',
					'spellcheck': 'false',
					'style': 'width:100%; white-space:pre; overflow:auto; font-family:monospace; font-size:90%'
				}, [ content != null ? content : '' ])
			])
		]);
	},

	handleSave: function() {
		return fs.write(CONFIG_PATH, currentValue()).then(function() {
			ui.addNotification(null, E('p', {}, _('Configuration saved.')), 'info');
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('Unable to save the configuration: %s').format(e.message)));
		});
	},

	handleSaveApply: function() {
		return fs.write(CONFIG_PATH, currentValue()).then(function() {
			return fs.exec('/etc/init.d/gatus', [ 'restart' ]);
		}).then(function() {
			ui.addNotification(null, E('p', {}, _('Configuration saved and Gatus restarted.')), 'info');
		}).catch(function(e) {
			ui.addNotification(null, E('p', {}, _('Unable to save/restart: %s').format(e.message)));
		});
	},

	handleReset: null
});
