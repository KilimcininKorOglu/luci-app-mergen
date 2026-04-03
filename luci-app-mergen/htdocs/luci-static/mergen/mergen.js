/* Mergen LuCI Client-Side Scripts */

'use strict';

var MergenUI = {

	rpcBase: L.url('admin', 'services', 'mergen', 'rpc'),

	/* XHR helper for RPC calls */
	rpcCall: function(endpoint, params) {
		var url = this.rpcBase + '/' + endpoint;
		return new Promise(function(resolve, reject) {
			var xhr = new XMLHttpRequest();
			xhr.open(params ? 'POST' : 'GET', url, true);
			xhr.setRequestHeader('Content-Type', 'application/x-www-form-urlencoded');
			xhr.responseType = 'json';
			xhr.timeout = 30000;

			xhr.onload = function() {
				if (xhr.status === 200) {
					resolve(xhr.response || {});
				} else {
					reject(new Error('HTTP ' + xhr.status));
				}
			};

			xhr.onerror = function() {
				reject(new Error('Network error'));
			};

			xhr.ontimeout = function() {
				reject(new Error('Request timeout'));
			};

			if (params) {
				var body = Object.keys(params).map(function(key) {
					return encodeURIComponent(key) + '=' + encodeURIComponent(params[key]);
				}).join('&');
				/* Include CSRF token */
				body += '&token=' + encodeURIComponent(
					document.querySelector('input[name="token"]')?.value || ''
				);
				xhr.send(body);
			} else {
				xhr.send();
			}
		});
	},

	/* Fetch and display status */
	refreshStatus: function() {
		var self = this;
		return self.rpcCall('status').then(function(data) {
			var el = document.getElementById('mergen-status-output');
			if (el && data.output) {
				el.textContent = data.output;
			}
			return data;
		}).catch(function(err) {
			console.error('Mergen status error:', err);
		});
	},

	/* Apply all rules */
	applyRules: function() {
		var btn = document.querySelector('.mergen-btn-apply');
		if (btn) btn.disabled = true;

		return this.rpcCall('apply', {}).then(function(data) {
			if (btn) btn.disabled = false;
			if (data.output) {
				alert(data.output);
			}
			location.reload();
		}).catch(function(err) {
			if (btn) btn.disabled = false;
			alert('Apply failed: ' + err.message);
		});
	},

	/* Update prefix lists */
	updatePrefixes: function() {
		var btn = document.querySelector('.mergen-btn-update');
		if (btn) btn.disabled = true;

		return this.rpcCall('update', {}).then(function(data) {
			if (btn) btn.disabled = false;
			if (data.output) {
				alert(data.output);
			}
			location.reload();
		}).catch(function(err) {
			if (btn) btn.disabled = false;
			alert('Update failed: ' + err.message);
		});
	},

	/* Restart daemon */
	restartDaemon: function() {
		var btn = document.querySelector('.mergen-btn-restart');
		if (btn) btn.disabled = true;

		return this.rpcCall('restart', {}).then(function(data) {
			if (btn) btn.disabled = false;
			location.reload();
		}).catch(function(err) {
			if (btn) btn.disabled = false;
			alert('Restart failed: ' + err.message);
		});
	},

	/* Toggle rule state */
	toggleRule: function(name, action) {
		return this.rpcCall('toggle', {
			name: name,
			action: action
		}).then(function() {
			location.reload();
		}).catch(function(err) {
			alert('Toggle failed: ' + err.message);
		});
	},

	/* Auto-refresh status every 30 seconds */
	startAutoRefresh: function(interval) {
		var self = this;
		interval = interval || 30000;
		setInterval(function() {
			self.refreshStatus();
		}, interval);
	},

	/* Initialize on page load */
	init: function() {
		var self = this;

		/* Bind action buttons */
		var applyBtn = document.querySelector('.mergen-btn-apply');
		if (applyBtn) {
			applyBtn.addEventListener('click', function(e) {
				e.preventDefault();
				self.applyRules();
			});
		}

		var updateBtn = document.querySelector('.mergen-btn-update');
		if (updateBtn) {
			updateBtn.addEventListener('click', function(e) {
				e.preventDefault();
				self.updatePrefixes();
			});
		}

		var restartBtn = document.querySelector('.mergen-btn-restart');
		if (restartBtn) {
			restartBtn.addEventListener('click', function(e) {
				e.preventDefault();
				if (confirm('Restart Mergen daemon?')) {
					self.restartDaemon();
				}
			});
		}

		/* Start auto-refresh on overview page */
		if (document.getElementById('mergen-status-output')) {
			self.startAutoRefresh();
		}
	}
};

/* Initialize when DOM is ready */
document.addEventListener('DOMContentLoaded', function() {
	MergenUI.init();
});
