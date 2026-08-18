/**
 * LetsLapse blend machine.
 *
 * Ported from the Claude Design source (LetsLapse Homepage.dc.html). The maths
 * is unchanged: every frame is composited at 1/N opacity, which is an exact
 * running mean of the stack — the same computation the app performs.
 *
 * Layout is two-up on desktop (source strip and output row on the left, big
 * stage on the right, their heights solved to match) and stacked on mobile.
 * Config and copy arrive as JSON on [data-ll-config]; colours and the label
 * font are read from CSS custom properties, so the canvas follows the theme.
 */
( function () {
	'use strict';

	var SELECTOR = '[data-ll-machine]';
	var MOBILE_MAX = 600;

	var BOUNDS = {
		cols: [ 1, 50 ],
		frames: [ 1, 500 ],
		frameSize: [ 16, 2048 ],
		srcFps: [ 1, 240 ],
		ratio: [ 2, 30 ],
		outputs: [ 2, 12 ],
		startRate: [ 0.5, 6 ],
		accel: [ 1, 2.5 ],
		maxRate: [ 4, 30 ],
		playFps: [ 1, 15 ]
	};

	var DEFAULTS = {
		cols: 11,
		frames: 120,
		frameSize: 320,
		srcFps: 15,
		ratio: 15,
		outputs: 8,
		startRate: 1.6,
		accel: 1.5,
		maxRate: 16,
		playFps: 5
	};

	var INTEGER_KEYS = [ 'cols', 'frames', 'frameSize', 'srcFps', 'ratio', 'outputs' ];

	function clamp( value, min, max ) {
		return Math.max( min, Math.min( max, value ) );
	}

	function isInteger( key ) {
		return INTEGER_KEYS.indexOf( key ) !== -1;
	}

	/**
	 * Reduce any CSS colour we can parse to an "r, g, b" triplet for rgba().
	 *
	 * @param {string} value CSS colour.
	 * @return {string|null} Triplet, or null when unparseable.
	 */
	function toTriplet( value ) {
		if ( ! value ) {
			return null;
		}

		var hex = value.trim();
		var rgb = hex.match( /^rgba?\(\s*([0-9.]+)[\s,]+([0-9.]+)[\s,]+([0-9.]+)/i );

		if ( rgb ) {
			return Math.round( rgb[ 1 ] ) + ', ' + Math.round( rgb[ 2 ] ) + ', ' + Math.round( rgb[ 3 ] );
		}

		if ( hex.charAt( 0 ) !== '#' ) {
			return null;
		}

		hex = hex.slice( 1 );

		if ( hex.length === 3 ) {
			hex = hex.charAt( 0 ) + hex.charAt( 0 ) + hex.charAt( 1 ) + hex.charAt( 1 ) + hex.charAt( 2 ) + hex.charAt( 2 );
		}

		if ( hex.length !== 6 ) {
			return null;
		}

		return parseInt( hex.slice( 0, 2 ), 16 ) + ', ' +
			parseInt( hex.slice( 2, 4 ), 16 ) + ', ' +
			parseInt( hex.slice( 4, 6 ), 16 );
	}

	function fill( template, tokens ) {
		return String( template ).replace( /\{(\w+)\}/g, function ( match, key ) {
			return Object.prototype.hasOwnProperty.call( tokens, key ) ? tokens[ key ] : match;
		} );
	}

	function hasCountToken( template ) {
		return /\{(index|total)\}/.test( String( template ) );
	}

	/**
	 * @param {HTMLElement} root Element carrying [data-ll-machine].
	 */
	function Machine( root ) {
		this.root = root;
		this.canvas = root.querySelector( 'canvas' );
		this.replayButton = root.querySelector( '[data-ll-replay]' );
		this.fallback = root.parentNode ? root.parentNode.querySelector( '[data-ll-fallback]' ) : null;

		if ( ! this.canvas ) {
			return;
		}

		this.c = this.parseConfig();
		this.labels = this.c.labels;
		this.raf = 0;
		this.visible = true;
		this.playIdx = 0;

		this.readPalette();
		this.relayout();
		this.resetSim();
		this.bind();
		this.loadAtlas();
	}

	Machine.prototype.parseConfig = function () {
		var raw = {};

		try {
			raw = JSON.parse( this.root.getAttribute( 'data-ll-config' ) || '{}' );
		} catch ( e ) {
			raw = {};
		}

		var config = {};
		var key;

		for ( key in DEFAULTS ) {
			if ( ! Object.prototype.hasOwnProperty.call( DEFAULTS, key ) ) {
				continue;
			}

			var value = typeof raw[ key ] === 'number' ? raw[ key ] : parseFloat( raw[ key ] );

			if ( isNaN( value ) ) {
				value = DEFAULTS[ key ];
			}

			value = clamp( value, BOUNDS[ key ][ 0 ], BOUNDS[ key ][ 1 ] );
			config[ key ] = isInteger( key ) ? Math.round( value ) : value;
		}

		config.atlas = raw.atlas || '';
		config.labels = raw.labels || {};
		config.showTimeline = false !== raw.showTimeline;
		config.showCount = false !== raw.showCount;

		return config;
	};

	Machine.prototype.readPalette = function () {
		var styles = window.getComputedStyle( this.root );

		function prop( name, fallback ) {
			var value = styles.getPropertyValue( name );
			value = value ? value.trim() : '';
			return value || fallback;
		}

		this.pal = {
			stage: prop( '--ll-machine-stage', '#060B16' ),
			accent: prop( '--ll-machine-accent', '#F0A32C' ),
			edge: prop( '--ll-machine-edge', 'rgba(36, 90, 133, 0.9)' ),
			inkRgb: prop( '--ll-machine-ink-rgb', '198, 210, 228' ),
			lineRgb: prop( '--ll-machine-line-rgb', '233, 238, 246' ),
			bgRgb: toTriplet( prop( '--ll-machine-bg', '#0A0F1C' ) ) || '10, 15, 28',
			font: prop( '--ll-machine-font', '' ) || styles.fontFamily ||
				'-apple-system, BlinkMacSystemFont, sans-serif'
		};

		this.pal.accentRgb = toTriplet( this.pal.accent ) || '240, 163, 44';
	};

	Machine.prototype.ink = function ( alpha ) {
		return 'rgba(' + this.pal.inkRgb + ', ' + alpha + ')';
	};

	Machine.prototype.line = function ( alpha ) {
		return 'rgba(' + this.pal.lineRgb + ', ' + alpha + ')';
	};

	Machine.prototype.amber = function ( alpha ) {
		return 'rgba(' + this.pal.accentRgb + ', ' + alpha + ')';
	};

	Machine.prototype.loadAtlas = function () {
		var self = this;
		var image = new Image();

		image.decoding = 'async';

		image.onload = function () {
			self.atlas = image;
			self.staticDone = false;

			// Paint one frame straight away. A page opened in a background tab
			// still shows a seeded machine rather than an empty canvas; the
			// animation loop is gated separately below.
			self.repaint();
			self.start();
		};

		image.onerror = function () {
			self.root.setAttribute( 'data-ll-error', '' );

			if ( self.fallback ) {
				self.fallback.hidden = false;
			}

			if ( window.console && window.console.warn ) {
				window.console.warn( 'LetsLapse: could not load the frame atlas at ' + self.c.atlas );
			}
		};

		image.src = this.c.atlas;
	};

	Machine.prototype.bind = function () {
		var self = this;

		this.reduced = window.matchMedia ? window.matchMedia( '( prefers-reduced-motion: reduce )' ) : null;

		if ( this.reduced ) {
			var onPreferenceChange = function () {
				self.staticDone = false;
				self.resetSim();
				self.start();
			};

			if ( this.reduced.addEventListener ) {
				this.reduced.addEventListener( 'change', onPreferenceChange );
			} else if ( this.reduced.addListener ) {
				this.reduced.addListener( onPreferenceChange );
			}
		}

		if ( window.ResizeObserver ) {
			this.observer = new ResizeObserver( function () {
				self.relayout();
			} );
			this.observer.observe( this.root );
		} else {
			window.addEventListener( 'resize', function () {
				self.relayout();
			} );
		}

		// Idle off-screen: the machine is decorative once it has scrolled away.
		if ( window.IntersectionObserver ) {
			this.inView = new IntersectionObserver( function ( entries ) {
				self.visible = entries[ 0 ].isIntersecting;

				if ( self.visible ) {
					self.start();
				} else {
					self.stop();
				}
			}, { rootMargin: '120px' } );
			this.inView.observe( this.root );
		}

		document.addEventListener( 'visibilitychange', function () {
			if ( document.hidden ) {
				self.stop();
			} else if ( self.visible ) {
				self.start();
			}
		} );

		if ( this.replayButton ) {
			this.replayButton.addEventListener( 'click', function () {
				self.replay();
			} );
		}
	};

	/**
	 * Draw a single frame in whichever mode currently applies.
	 */
	Machine.prototype.repaint = function () {
		if ( ! this.atlas || ! this.L || ! this.canvas ) {
			return;
		}

		if ( this.reduced && this.reduced.matches ) {
			this.drawStatic();
		} else {
			this.draw();
		}
	};

	Machine.prototype.start = function () {
		if ( this.raf || ! this.atlas || document.hidden || ! this.visible ) {
			return;
		}

		var self = this;

		this.last = performance.now();

		var loop = function ( time ) {
			self.raf = requestAnimationFrame( loop );

			var dt = Math.min( 0.05, ( time - self.last ) / 1000 );
			self.last = time;

			if ( ! self.atlas || ! self.L || ! self.canvas ) {
				return;
			}

			if ( self.reduced && self.reduced.matches ) {
				self.drawStatic();

				if ( self.staticDone ) {
					self.stop();
				}

				return;
			}

			self.tick( dt );
			self.draw();
		};

		this.raf = requestAnimationFrame( loop );
	};

	Machine.prototype.stop = function () {
		if ( this.raf ) {
			cancelAnimationFrame( this.raf );
			this.raf = 0;
		}
	};

	/**
	 * Solve the layout for the current width.
	 *
	 * Desktop is two columns: the source strip and the output row stack in the
	 * left column, and the square stage fills the right one. The stage size and
	 * the column width depend on each other, so four passes settle them.
	 */
	Machine.prototype.relayout = function () {
		var c = this.c;
		var w = this.root.clientWidth;

		if ( ! w ) {
			return;
		}

		var mobile = w <= MOBILE_MAX;
		var stripY = 26;
		var S, colW, F, g, g2, Fo, stageX, stageY, outY;

		if ( mobile ) {
			// Single column: strip → stage → output row → timeline.
			colW = w;
			F = Math.floor( w / 3.4 );
			g = Math.round( F * 0.08 );
			g2 = 3;
			Fo = Math.max( 16, Math.floor( ( w - ( c.outputs - 1 ) * g2 ) / c.outputs ) );
			S = Math.min( w, 340 );
			stageX = Math.round( ( w - S ) / 2 );
			stageY = stripY + F + 30;
			outY = stageY + S + 30;
		} else {
			var gap12 = Math.round( Math.max( 14, w * 0.03 ) );
			var midGap = 26;

			S = Math.round( w * 0.28 );

			for ( var it = 0; it < 4; it++ ) {
				colW = w - S - gap12;
				F = Math.min( 200, Math.floor( colW / ( w > 700 ? 4.4 : 2.4 ) ) );
				g = Math.round( F * 0.08 );
				g2 = colW / c.outputs > 46 ? Math.round( F * 0.06 ) : 3;
				Fo = Math.max( 16, Math.min( F, Math.floor( ( colW - ( c.outputs - 1 ) * g2 ) / c.outputs ) ) );
				S = Math.max( 140, Math.min( 360, F + midGap + Fo ) );
			}

			stageX = colW + gap12;
			stageY = stripY;
			outY = stripY + S - Fo;
		}

		var dropX = Math.round( F * 0.7 );
		var gateX = colW - F;
		var rowsBottom = mobile ? outY + Fo : stripY + S;
		var tlX = 0;
		var tlW = w - 2;
		var Th = 16;
		var tlY = rowsBottom + 38;

		// With the timeline row off, the status line closes the gap up.
		var statusY = c.showTimeline ? tlY - 8 : rowsBottom + 24;
		var H = c.showTimeline ? tlY + Th + 10 : rowsBottom + 32;

		this.L = {
			w: w, colW: colW, F: F, g: g, dropX: dropX, gateX: gateX, S: S,
			stageX: stageX, stageY: stageY, stripY: stripY, outY: outY, Fo: Fo, g2: g2,
			tlX: tlX, tlW: tlW, tlY: tlY, Th: Th, statusY: statusY, rowsBottom: rowsBottom,
			H: H, mobile: mobile
		};

		var dpr = window.devicePixelRatio || 1;

		this.canvas.width = Math.round( w * dpr );
		this.canvas.height = Math.round( H * dpr );
		this.canvas.style.height = H + 'px';
		this.dpr = dpr;
		this.staticDone = false;

		if ( this.replayButton ) {
			this.replayButton.style.left = Math.round( colW / 2 ) + 'px';
			this.replayButton.style.top = Math.round( stripY + F / 2 - 21 ) + 'px';
		}

		this.repaint();
	};

	Machine.prototype.newC = function () {
		var canvas = document.createElement( 'canvas' );
		canvas.width = this.c.frameSize;
		canvas.height = this.c.frameSize;
		return canvas;
	};

	Machine.prototype.frXY = function ( fi ) {
		var c = this.c;
		return [ ( fi % c.cols ) * c.frameSize, Math.floor( fi / c.cols ) * c.frameSize ];
	};

	Machine.prototype.resetSim = function () {
		this.S = {
			strip: [], nextF: 0, feed: 0, dropCount: 0, stripFade: 1, drops: [],
			stackC: this.newC(), stackN: 0, pending: null, eject: null, outs: [],
			batch: 0, phase: 'run', playT: 0, resetT: 0, rate: 1
		};
		this.seedStrip();
		this.setReplayVisible( false );
	};

	Machine.prototype.seedStrip = function () {
		var L = this.L;
		var S = this.S;
		var c = this.c;

		if ( ! L ) {
			return;
		}

		var x = L.dropX + L.F + L.g;

		while ( x < L.w + L.F ) {
			S.strip.push( { fi: S.nextF % c.frames, x: x } );
			S.nextF++;
			x += L.F + L.g;
		}
	};

	Machine.prototype.setReplayVisible = function ( visible ) {
		if ( ! this.replayButton ) {
			return;
		}

		this.replayButton.hidden = ! visible;
	};

	Machine.prototype.land = function ( fi ) {
		var S = this.S;
		var c = this.c;

		if ( S.pending && S.stackN === 0 ) {
			if ( S.eject ) {
				this.completeEject();
			}

			if ( S.phase === 'run' && S.outs.length < c.outputs ) {
				S.eject = { c: S.pending, t: 0 };
			}

			S.pending = null;
		}

		var ctx = S.stackC.getContext( '2d' );
		var xy = this.frXY( fi );

		S.stackN++;
		ctx.globalAlpha = 1 / S.stackN;
		ctx.drawImage( this.atlas, xy[ 0 ], xy[ 1 ], c.frameSize, c.frameSize, 0, 0, c.frameSize, c.frameSize );

		if ( S.stackN >= c.ratio ) {
			if ( S.pending && S.phase === 'run' ) {
				S.outs.push( S.pending );
				S.batch++;
			}

			S.pending = S.stackC;
			S.stackC = this.newC();
			S.stackN = 0;
		}
	};

	Machine.prototype.completeEject = function () {
		var S = this.S;
		var c = this.c;

		S.outs.push( S.eject.c );
		S.eject = null;
		S.batch++;

		if ( S.batch >= c.outputs && S.phase === 'run' ) {
			S.phase = 'play';
			S.playT = 0;
			this.setReplayVisible( true );
		}
	};

	Machine.prototype.tick = function ( dt ) {
		var c = this.c;
		var L = this.L;
		var S = this.S;
		var needed = c.outputs * c.ratio;
		var feeding = S.phase === 'run' && S.dropCount < needed;
		var rate = Math.min( c.maxRate, c.startRate * Math.pow( c.accel, S.batch ) );

		S.rate = rate;

		if ( feeding ) {
			S.stripFade = Math.min( 1, S.stripFade + dt / 0.6 );
		} else if ( ! S.drops.length ) {
			S.stripFade = Math.max( 0, S.stripFade - dt / 0.8 );
		}

		if ( feeding ) {
			var pitch = L.F + L.g;
			// Ratchet: full dwell-and-snap indexing on the first blends, easing
			// out to linear belt travel by blend 4.
			var k = Math.max( 0, 1 - S.batch / 3 );
			var shape = function ( s ) {
				var dwell = 0.45 * k;
				var m = s <= dwell ? 0 : ( s - dwell ) / ( 1 - dwell );
				var b = 1 - Math.pow( 1 - m, 3 );
				return s + ( b - s ) * k;
			};
			var travel = function ( ph ) {
				return ( Math.floor( ph ) + shape( ph - Math.floor( ph ) ) ) * pitch;
			};
			var prev = travel( S.feed );

			S.feed += dt * rate;

			var dx = travel( S.feed ) - prev;

			for ( var i = 0; i < S.strip.length; i++ ) {
				S.strip[ i ].x -= dx;
			}

			while ( S.strip.length && S.strip[ 0 ].x <= L.dropX + 0.5 ) {
				var frame = S.strip.shift();

				S.drops.push( { fi: frame.fi, t: 0 } );
				S.dropCount++;

				if ( S.dropCount >= needed ) {
					break;
				}
			}
		}

		var lastX = S.strip.length ? S.strip[ S.strip.length - 1 ].x : L.dropX;

		while ( lastX + L.F + L.g < L.w + L.F ) {
			lastX += L.F + L.g;
			S.strip.push( { fi: S.nextF % c.frames, x: lastX } );
			S.nextF++;
		}

		var dropDuration = clamp( 0.85 / rate, 0.2, 0.75 );

		for ( var d = 0; d < S.drops.length; d++ ) {
			S.drops[ d ].t += dt / dropDuration;
		}

		while ( S.drops.length && S.drops[ 0 ].t >= 1 ) {
			this.land( S.drops.shift().fi );
		}

		if ( S.pending && ! S.eject && S.phase === 'run' && S.dropCount >= needed && ! S.drops.length ) {
			S.eject = { c: S.pending, t: 0 };
			S.pending = null;
		}

		if ( S.eject ) {
			S.eject.t += dt / clamp( 0.9 / rate, 0.25, 0.8 );

			if ( S.eject.t >= 1 ) {
				this.completeEject();
			}
		}

		if ( S.phase === 'play' ) {
			S.playT += dt;
		}

		if ( S.phase === 'reset' ) {
			S.resetT += dt;

			if ( S.resetT >= 0.7 ) {
				S.outs = [];
				S.batch = 0;
				S.stackC = this.newC();
				S.stackN = 0;
				S.pending = null;
				S.drops = [];
				S.feed = 0;
				S.dropCount = 0;
				S.nextF = 0;
				S.strip = [];
				this.seedStrip();
				S.phase = 'run';
			}
		}
	};

	Machine.prototype.replay = function () {
		var S = this.S;

		if ( ! S || S.phase !== 'play' ) {
			return;
		}

		S.phase = 'reset';
		S.resetT = 0;
		this.setReplayVisible( false );
	};

	Machine.prototype.slotRect = function ( i ) {
		var L = this.L;
		return [ i * ( L.Fo + L.g2 ), L.outY, L.Fo, L.Fo ];
	};

	Machine.prototype.drawBrackets = function ( ctx, x, y, s, color, lineWidth ) {
		var k = s * 0.28;

		ctx.strokeStyle = color;
		ctx.lineWidth = lineWidth;
		ctx.lineCap = 'round';
		ctx.beginPath();
		ctx.moveTo( x, y + k ); ctx.lineTo( x, y ); ctx.lineTo( x + k, y );
		ctx.moveTo( x + s - k, y ); ctx.lineTo( x + s, y ); ctx.lineTo( x + s, y + k );
		ctx.moveTo( x + s, y + s - k ); ctx.lineTo( x + s, y + s ); ctx.lineTo( x + s - k, y + s );
		ctx.moveTo( x + k, y + s ); ctx.lineTo( x, y + s ); ctx.lineTo( x, y + s - k );
		ctx.stroke();
	};

	/**
	 * Compose the status line for the current phase.
	 *
	 * @return {string} Status text, or '' when its label is blank.
	 */
	Machine.prototype.statusText = function () {
		var c = this.c;
		var S = this.S;
		var labels = this.labels;

		if ( S.phase === 'run' ) {
			if ( ! labels.stacking ) {
				return '';
			}

			return fill( labels.stacking, {
				stacked: S.stackN,
				ratio: c.ratio,
				blend: Math.min( S.batch + 1, c.outputs ),
				outputs: c.outputs
			} );
		}

		if ( S.phase === 'play' ) {
			if ( ! labels.playing ) {
				return '';
			}

			var tokens = { index: this.playIdx + 1, total: S.outs.length };

			// Tokens placed in the label win; otherwise the counter toggle
			// appends the default "n / x".
			if ( hasCountToken( labels.playing ) ) {
				return fill( labels.playing, tokens );
			}

			return c.showCount
				? labels.playing + ' ' + tokens.index + ' / ' + tokens.total
				: labels.playing;
		}

		return labels.resetting || '';
	};

	Machine.prototype.draw = function () {
		var c = this.c;
		var L = this.L;
		var S = this.S;
		var ctx = this.canvas.getContext( '2d' );
		var self = this;
		var FR = c.frameSize;
		var i;

		ctx.setTransform( this.dpr, 0, 0, this.dpr, 0, 0 );
		ctx.clearRect( 0, 0, L.w, L.H );

		var label = function ( text, x, y, align ) {
			if ( ! text ) {
				return;
			}

			ctx.font = '600 11px ' + self.pal.font;
			ctx.fillStyle = self.ink( 0.5 );
			ctx.textAlign = align || 'left';
			ctx.fillText( text, x, y );
			ctx.textAlign = 'left';
		};

		label( this.labels.output, 0, L.outY - 8 );

		if ( c.showTimeline ) {
			label( this.labels.timeline, L.tlX, L.tlY - 8 );
		}

		var playing = S.phase === 'play' || S.phase === 'reset';

		this.playIdx = 0;

		if ( playing && S.outs.length ) {
			this.playIdx = Math.floor( S.playT * c.playFps ) % S.outs.length;
		}

		var playIdx = this.playIdx;
		var status = this.statusText();

		if ( status ) {
			ctx.font = '600 12px ' + this.pal.font;
			ctx.fillStyle = this.ink( 0.65 );
			ctx.textAlign = 'right';
			ctx.fillText( status, L.w - 2, L.statusY );
			ctx.textAlign = 'left';
		}

		var fade = S.phase === 'reset' ? Math.max( 0, 1 - S.resetT / 0.7 ) : 1;

		if ( c.showTimeline ) {
			var segG = 3;
			var segW = ( L.tlW - ( c.outputs - 1 ) * segG ) / c.outputs;
			var x;

			for ( i = 0; i < c.outputs; i++ ) {
				x = L.tlX + i * ( segW + segG );

				if ( i < S.outs.length ) {
					ctx.globalAlpha = fade;
					ctx.fillStyle = S.phase === 'play' && i === playIdx ? this.amber( 0.75 ) : this.amber( 0.35 );
					ctx.fillRect( x, L.tlY, segW, L.Th );
					ctx.globalAlpha = 1;
				} else if ( i === S.batch && S.stackN > 0 ) {
					// The segment being built grows with every frame that stacks.
					ctx.fillStyle = this.amber( 0.35 );
					ctx.fillRect( x, L.tlY, segW * ( S.stackN / c.ratio ), L.Th );
				}

				ctx.strokeStyle = this.ink( 0.16 );
				ctx.lineWidth = 1;
				ctx.strokeRect( x + 0.5, L.tlY + 0.5, segW - 1, L.Th - 1 );
			}

			if ( S.phase === 'play' && S.outs.length ) {
				var progress = ( S.playT * c.playFps % S.outs.length ) / c.outputs;
				var px = L.tlX + progress * L.tlW;

				ctx.strokeStyle = this.pal.accent;
				ctx.lineWidth = 2;
				ctx.beginPath();
				ctx.moveTo( px, L.tlY - 4 );
				ctx.lineTo( px, L.tlY + L.Th + 4 );
				ctx.stroke();
			}
		}

		// Empty slots, so the run has a visible destination from the first frame.
		ctx.setLineDash( [ 4, 4 ] );
		ctx.strokeStyle = this.ink( 0.14 );
		ctx.lineWidth = 1;

		for ( i = 0; i < c.outputs; i++ ) {
			var empty = this.slotRect( i );
			ctx.strokeRect( empty[ 0 ] + 0.5, empty[ 1 ] + 0.5, empty[ 2 ] - 1, empty[ 2 ] - 1 );
		}

		ctx.setLineDash( [] );

		// Desktop fills the row from the right, so finished blends slide left as
		// the next one is ejected. Mobile fills from the left instead.
		var mShift = ! L.mobile && S.eject
			? ( 1 - Math.pow( 1 - Math.min( 1, S.eject.t ), 3 ) ) * ( L.Fo + L.g2 )
			: 0;

		for ( i = 0; i < S.outs.length; i++ ) {
			var slot = this.slotRect( L.mobile ? i : c.outputs - S.outs.length + i );
			var sx = slot[ 0 ] - mShift;

			ctx.globalAlpha = fade;
			ctx.drawImage( S.outs[ i ], sx, slot[ 1 ], slot[ 2 ], slot[ 2 ] );
			ctx.globalAlpha = 1;

			if ( S.phase === 'play' && i === playIdx ) {
				ctx.strokeStyle = this.pal.accent;
				ctx.lineWidth = 2;
				ctx.strokeRect( sx - 1.5, slot[ 1 ] - 1.5, slot[ 2 ] + 3, slot[ 2 ] + 3 );
			} else {
				ctx.strokeStyle = this.line( 0.1 );
				ctx.lineWidth = 1;
				ctx.strokeRect( sx + 0.5, slot[ 1 ] + 0.5, slot[ 2 ] - 1, slot[ 2 ] - 1 );
			}
		}

		ctx.fillStyle = this.pal.stage;
		ctx.fillRect( L.stageX, L.stageY, L.S, L.S );

		if ( playing && S.outs.length ) {
			ctx.drawImage( S.outs[ playIdx ], L.stageX, L.stageY, L.S, L.S );
		} else if ( S.stackN > 0 ) {
			ctx.drawImage( S.stackC, L.stageX, L.stageY, L.S, L.S );
		} else if ( S.pending ) {
			ctx.drawImage( S.pending, L.stageX, L.stageY, L.S, L.S );
		}

		ctx.strokeStyle = playing ? this.pal.accent : this.pal.edge;
		ctx.lineWidth = playing ? 2 : 1.5;
		ctx.strokeRect( L.stageX + 0.5, L.stageY + 0.5, L.S - 1, L.S - 1 );

		var tickW = ( L.S - 12 ) / c.ratio;

		for ( i = 0; i < c.ratio; i++ ) {
			ctx.fillStyle = i < S.stackN ? this.pal.accent : this.ink( 0.15 );
			ctx.fillRect( L.stageX + 6 + i * tickW, L.stageY + L.S - 7, Math.max( 1, tickW - 2 ), 3 );
		}

		if ( S.eject ) {
			var t = Math.min( 1, S.eject.t );
			var e = 1 - Math.pow( 1 - t, 3 );
			var target = this.slotRect( L.mobile ? Math.min( S.outs.length, c.outputs - 1 ) : c.outputs - 1 );
			var ex = L.stageX + ( target[ 0 ] - L.stageX ) * e;
			var ey = L.stageY + ( target[ 1 ] - L.stageY ) * e;
			var size = L.S + ( target[ 2 ] - L.S ) * e;

			ctx.drawImage( S.eject.c, ex, ey, size, size );
			ctx.strokeStyle = this.amber( 0.7 );
			ctx.lineWidth = 1;
			ctx.strokeRect( ex + 0.5, ey + 0.5, size - 1, size - 1 );
		}

		if ( S.stripFade > 0.01 ) {
			ctx.globalAlpha = S.stripFade;

			// On mobile the reduced-motion note takes this baseline instead:
			// there is not enough width for both.
			if ( ! ( this.staticPass && L.mobile ) ) {
				label( this.labels.source, 0, L.stripY - 10 );
			}

			ctx.strokeStyle = this.line( 0.1 );
			ctx.lineWidth = 1;

			for ( i = 0; i < S.strip.length; i++ ) {
				var frame = S.strip[ i ];
				// The strip runs left to right into the gate at the column edge.
				var vx = L.gateX - ( frame.x - L.dropX );

				if ( vx + L.F < -2 ) {
					break;
				}

				var fxy = this.frXY( frame.fi );

				ctx.drawImage( this.atlas, fxy[ 0 ], fxy[ 1 ], FR, FR, vx, L.stripY, L.F, L.F );
				ctx.strokeRect( vx + 0.5, L.stripY + 0.5, L.F - 1, L.F - 1 );
			}

			var fadeW = L.F * 1.2;
			var grad = ctx.createLinearGradient( fadeW, 0, 0, 0 );

			grad.addColorStop( 0, 'rgba(' + this.pal.bgRgb + ', 0)' );
			grad.addColorStop( 1, 'rgba(' + this.pal.bgRgb + ', 1)' );
			ctx.fillStyle = grad;
			ctx.fillRect( 0, L.stripY - 2, fadeW, L.F + 4 );

			this.drawBrackets( ctx, L.gateX - 6, L.stripY - 6, L.F + 12, this.pal.accent, 3 );
			ctx.globalAlpha = 1;
		}

		for ( i = 0; i < S.drops.length; i++ ) {
			var drop = S.drops[ i ];
			var dt2 = Math.min( 1, drop.t );
			var de = dt2 * dt2;
			var dsize = L.F + ( L.S - L.F ) * de;
			var dx2 = L.gateX + ( L.stageX - L.gateX ) * de;
			var dy2 = L.stripY + ( L.stageY - L.stripY ) * de;
			var dxy = this.frXY( drop.fi );

			ctx.globalAlpha = 1 - dt2 * ( 1 - 1 / ( S.stackN + 1 ) );
			ctx.drawImage( this.atlas, dxy[ 0 ], dxy[ 1 ], FR, FR, dx2, dy2, dsize, dsize );
			ctx.globalAlpha = 1;
		}
	};

	/**
	 * Reduced-motion rendering: the finished stack as a still diagram.
	 */
	Machine.prototype.drawStatic = function () {
		if ( this.staticDone ) {
			return;
		}

		var c = this.c;
		var S = this.S;
		var i;
		var xy;

		S.strip = [];
		S.nextF = c.ratio;
		S.drops = [];
		S.eject = null;
		this.seedStrip();

		S.stackC = this.newC();
		S.stackN = 0;

		var stackCtx = S.stackC.getContext( '2d' );

		for ( i = 0; i < c.ratio; i++ ) {
			stackCtx.globalAlpha = 1 / ( i + 1 );
			xy = this.frXY( i );
			stackCtx.drawImage( this.atlas, xy[ 0 ], xy[ 1 ], c.frameSize, c.frameSize, 0, 0, c.frameSize, c.frameSize );
		}

		S.stackN = c.ratio - 1;
		S.outs = [];

		for ( var o = 0; o < c.outputs; o++ ) {
			var out = this.newC();
			var outCtx = out.getContext( '2d' );

			for ( i = 0; i < c.ratio; i++ ) {
				outCtx.globalAlpha = 1 / ( i + 1 );
				xy = this.frXY( ( o * c.ratio + i ) % c.frames );
				outCtx.drawImage( this.atlas, xy[ 0 ], xy[ 1 ], c.frameSize, c.frameSize, 0, 0, c.frameSize, c.frameSize );
			}

			S.outs.push( out );
		}

		S.batch = c.outputs;
		S.phase = 'run';
		this.staticPass = true;
		this.draw();
		this.staticPass = false;

		if ( this.labels.reduced ) {
			var ctx = this.canvas.getContext( '2d' );
			var mobile = this.L.mobile;

			ctx.font = '600 11px ' + this.pal.font;
			ctx.fillStyle = this.ink( 0.5 );
			ctx.textAlign = mobile ? 'left' : 'right';
			ctx.fillText( this.labels.reduced, mobile ? 0 : this.L.w - 2, this.L.stripY - 10 );
			ctx.textAlign = 'left';
		}

		this.staticDone = true;
		S.batch = 0;
		S.phase = 'run';
	};

	Machine.prototype.destroy = function () {
		this.stop();

		if ( this.observer ) {
			this.observer.disconnect();
		}

		if ( this.inView ) {
			this.inView.disconnect();
		}
	};

	/**
	 * Boot every machine inside a scope. Safe to call repeatedly.
	 *
	 * @param {Document|Element} scope Optional container.
	 */
	function init( scope ) {
		var nodes = ( scope || document ).querySelectorAll( SELECTOR );

		for ( var i = 0; i < nodes.length; i++ ) {
			if ( ! nodes[ i ].llMachine ) {
				nodes[ i ].llMachine = new Machine( nodes[ i ] );
			}
		}
	}

	window.LetsLapseMachine = { init: init, Machine: Machine };

	if ( document.readyState === 'loading' ) {
		document.addEventListener( 'DOMContentLoaded', function () {
			init();
		} );
	} else {
		init();
	}
}() );
