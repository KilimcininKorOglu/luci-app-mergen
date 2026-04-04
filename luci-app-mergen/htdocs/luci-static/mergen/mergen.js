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
	},

	/* ──────────────────────────────────────────────
	 * Rules Page Advanced: drag-drop, bulk ops,
	 * clone, JSON export (T038)
	 * ────────────────────────────────────────────── */

	/* Clone a rule */
	cloneRule: function(sourceName) {
		var newName = prompt('Enter name for the cloned rule:', sourceName + '-copy');
		if (!newName) return;
		newName = newName.replace(/[^a-zA-Z0-9_-]/g, '');
		if (!newName) {
			alert('Invalid rule name');
			return;
		}
		return this.rpcCall('clone', {
			source: sourceName,
			new_name: newName
		}).then(function(data) {
			if (data.success) {
				location.reload();
			} else {
				alert('Clone failed: ' + (data.error || 'Unknown error'));
			}
		}).catch(function(err) {
			alert('Clone failed: ' + err.message);
		});
	},

	/* Bulk operation on selected rules */
	bulkAction: function(action) {
		var checkboxes = document.querySelectorAll('.mergen-rule-cb:checked');
		if (checkboxes.length === 0) {
			alert('No rules selected');
			return;
		}

		if (action === 'delete') {
			if (!confirm('Delete ' + checkboxes.length + ' selected rules?')) {
				return;
			}
		}

		var names = [];
		for (var i = 0; i < checkboxes.length; i++) {
			names.push(checkboxes[i].getAttribute('data-rule'));
		}

		return this.rpcCall('bulk', {
			action: action,
			rules: names.join(',')
		}).then(function(data) {
			if (data.success) {
				location.reload();
			} else {
				alert('Bulk operation failed: ' + (data.error || 'Unknown error'));
			}
		}).catch(function(err) {
			alert('Bulk operation failed: ' + err.message);
		});
	},

	/* Export rules as JSON download */
	exportRules: function() {
		var self = this;
		/* Collect selected rule names (empty = all) */
		var checkboxes = document.querySelectorAll('.mergen-rule-cb:checked');
		var selectedNames = [];
		for (var i = 0; i < checkboxes.length; i++) {
			selectedNames.push(checkboxes[i].getAttribute('data-rule'));
		}

		return self.rpcCall('export_rules').then(function(data) {
			if (!data.success || !data.rules) {
				alert('Export failed');
				return;
			}

			var rules = data.rules;
			/* Filter if specific rules are selected */
			if (selectedNames.length > 0) {
				rules = rules.filter(function(r) {
					return selectedNames.indexOf(r.name) !== -1;
				});
			}

			var blob = new Blob(
				[JSON.stringify({ rules: rules }, null, 2)],
				{ type: 'application/json' }
			);
			var url = URL.createObjectURL(blob);
			var a = document.createElement('a');
			a.href = url;
			a.download = 'mergen-rules.json';
			document.body.appendChild(a);
			a.click();
			document.body.removeChild(a);
			URL.revokeObjectURL(url);
		}).catch(function(err) {
			alert('Export failed: ' + err.message);
		});
	},

	/* Save reordered priorities to backend */
	saveReorder: function(order) {
		return this.rpcCall('reorder', {
			order: JSON.stringify(order)
		}).then(function(data) {
			if (!data.success) {
				alert('Reorder failed: ' + (data.error || 'Unknown error'));
			}
		}).catch(function(err) {
			alert('Reorder failed: ' + err.message);
		});
	},

	/* Initialize rules page enhancements */
	initRulesAdvanced: function() {
		var self = this;
		var table = document.querySelector('.cbi-section-table');
		if (!table) return;

		var tbody = table.querySelector('tbody') || table;
		var rows = tbody.querySelectorAll('.cbi-section-table-row');
		if (rows.length === 0) return;

		/* ── Inject checkbox column ── */
		var headerRow = table.querySelector('.cbi-section-table-titles');
		if (headerRow) {
			var thCb = document.createElement('th');
			thCb.className = 'cbi-section-table-cell';
			thCb.innerHTML = '<input type="checkbox" id="mergen-select-all" '
				+ 'title="Select all">';
			headerRow.insertBefore(thCb, headerRow.firstChild);
		}

		for (var i = 0; i < rows.length; i++) {
			var row = rows[i];
			var sectionId = self._getRowSectionId(row);
			var tdCb = document.createElement('td');
			tdCb.className = 'cbi-section-table-cell';
			tdCb.innerHTML = '<input type="checkbox" class="mergen-rule-cb" '
				+ 'data-rule="' + sectionId + '">';
			row.insertBefore(tdCb, row.firstChild);

			/* ── Make row draggable ── */
			row.setAttribute('draggable', 'true');
			row.setAttribute('data-section', sectionId);
			row.classList.add('mergen-draggable');

			/* ── Add clone button to actions cell ── */
			var actionsCells = row.querySelectorAll('td');
			var lastCell = actionsCells[actionsCells.length - 1];
			if (lastCell) {
				var cloneBtn = document.createElement('button');
				cloneBtn.className = 'cbi-button cbi-button-neutral mergen-btn-clone';
				cloneBtn.textContent = 'Clone';
				cloneBtn.setAttribute('data-rule', sectionId);
				cloneBtn.addEventListener('click', function(e) {
					e.preventDefault();
					var ruleName = this.getAttribute('data-rule');
					self.cloneRule(ruleName);
				});
				lastCell.appendChild(document.createTextNode(' '));
				lastCell.appendChild(cloneBtn);
			}
		}

		/* ── Select all checkbox ── */
		var selectAll = document.getElementById('mergen-select-all');
		if (selectAll) {
			selectAll.addEventListener('change', function() {
				var cbs = document.querySelectorAll('.mergen-rule-cb');
				for (var j = 0; j < cbs.length; j++) {
					cbs[j].checked = this.checked;
				}
				self._updateBulkToolbar();
			});
		}

		/* Track checkbox changes for toolbar state */
		document.addEventListener('change', function(e) {
			if (e.target.classList.contains('mergen-rule-cb')) {
				self._updateBulkToolbar();
			}
		});

		/* ── Drag and drop ── */
		var dragSrc = null;

		tbody.addEventListener('dragstart', function(e) {
			var row = e.target.closest('.cbi-section-table-row');
			if (!row) return;
			dragSrc = row;
			row.classList.add('mergen-dragging');
			e.dataTransfer.effectAllowed = 'move';
			e.dataTransfer.setData('text/plain', row.getAttribute('data-section'));
		});

		tbody.addEventListener('dragover', function(e) {
			e.preventDefault();
			e.dataTransfer.dropEffect = 'move';
			var target = e.target.closest('.cbi-section-table-row');
			if (target && target !== dragSrc) {
				var rect = target.getBoundingClientRect();
				var midY = rect.top + rect.height / 2;
				if (e.clientY < midY) {
					target.classList.add('mergen-drop-above');
					target.classList.remove('mergen-drop-below');
				} else {
					target.classList.add('mergen-drop-below');
					target.classList.remove('mergen-drop-above');
				}
			}
		});

		tbody.addEventListener('dragleave', function(e) {
			var target = e.target.closest('.cbi-section-table-row');
			if (target) {
				target.classList.remove('mergen-drop-above', 'mergen-drop-below');
			}
		});

		tbody.addEventListener('drop', function(e) {
			e.preventDefault();
			var target = e.target.closest('.cbi-section-table-row');
			if (!target || !dragSrc || target === dragSrc) return;

			var rect = target.getBoundingClientRect();
			var midY = rect.top + rect.height / 2;

			if (e.clientY < midY) {
				tbody.insertBefore(dragSrc, target);
			} else {
				tbody.insertBefore(dragSrc, target.nextSibling);
			}

			/* Clean up visual hints */
			var allRows = tbody.querySelectorAll('.cbi-section-table-row');
			for (var k = 0; k < allRows.length; k++) {
				allRows[k].classList.remove(
					'mergen-drop-above', 'mergen-drop-below');
			}

			/* Recalculate priorities and save */
			self._recalcPriorities();
		});

		tbody.addEventListener('dragend', function(e) {
			if (dragSrc) {
				dragSrc.classList.remove('mergen-dragging');
			}
			dragSrc = null;
			var allRows = tbody.querySelectorAll('.cbi-section-table-row');
			for (var k = 0; k < allRows.length; k++) {
				allRows[k].classList.remove(
					'mergen-drop-above', 'mergen-drop-below');
			}
		});
	},

	/* Extract UCI section ID from a CBI table row */
	_getRowSectionId: function(row) {
		/* CBI tblsection rows have id like "cbi-mergen-SECTIONNAME" */
		var id = row.id || '';
		var match = id.match(/^cbi-mergen-(.+)$/);
		if (match) return match[1];

		/* Fallback: look for an input element with name pattern */
		var input = row.querySelector('input[id*=".name"]');
		if (input && input.value) return input.value;

		/* Last fallback: row index */
		return 'row-' + Array.prototype.indexOf.call(
			row.parentNode.children, row);
	},

	/* Recalculate priorities after drag-drop reorder */
	_recalcPriorities: function() {
		var self = this;
		var rows = document.querySelectorAll(
			'.cbi-section-table-row[data-section]');
		var order = [];
		var base = 100;
		var step = 10;

		for (var i = 0; i < rows.length; i++) {
			var sectionId = rows[i].getAttribute('data-section');
			var newPriority = base + (i * step);
			order.push({ name: sectionId, priority: newPriority });

			/* Also update the visible priority input in the row */
			var priInput = rows[i].querySelector(
				'input[id*=".priority"]');
			if (priInput) {
				priInput.value = newPriority;
			}
		}

		self.saveReorder(order);
	},

	/* Update bulk toolbar visibility based on selection */
	_updateBulkToolbar: function() {
		var checked = document.querySelectorAll('.mergen-rule-cb:checked');
		var toolbar = document.getElementById('mergen-bulk-toolbar');
		if (toolbar) {
			toolbar.style.display = checked.length > 0 ? 'flex' : 'none';
			var countEl = document.getElementById('mergen-bulk-count');
			if (countEl) {
				countEl.textContent = checked.length;
			}
		}
	}
};

/* Initialize when DOM is ready */
document.addEventListener('DOMContentLoaded', function() {
	MergenUI.init();

	/* Initialize rules page enhancements if on rules page */
	if (document.querySelector('.cbi-section-table') &&
		window.location.href.indexOf('/rules') !== -1) {
		MergenUI.initRulesAdvanced();
	}
});
