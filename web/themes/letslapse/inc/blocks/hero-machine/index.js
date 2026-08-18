/**
 * Blend machine — editor.
 *
 * No build step: this is plain ES5 against the wp.* globals, so the theme is
 * installable as-is. The editor shows a schematic of the real two-up layout
 * carrying whatever copy is set; the canvas itself runs on the front end.
 */
( function ( wp ) {
	'use strict';

	if ( ! wp || ! wp.blocks || ! wp.element ) {
		return;
	}

	var el = wp.element.createElement;
	var Fragment = wp.element.Fragment;
	var __ = wp.i18n.__;
	var blockEditor = wp.blockEditor;
	var components = wp.components;

	var useBlockProps = blockEditor.useBlockProps;
	var InspectorControls = blockEditor.InspectorControls;
	var MediaUpload = blockEditor.MediaUpload;
	var MediaUploadCheck = blockEditor.MediaUploadCheck;

	var PanelBody = components.PanelBody;
	var RangeControl = components.RangeControl;
	var ToggleControl = components.ToggleControl;
	var TextControl = components.TextControl;
	var Button = components.Button;

	var data = window.letsLapseHero || {};
	var schema = data.schema || {};
	var labelDefaults = data.labelDefaults || {};

	function rule( key ) {
		return schema[ key ] || { 'default': 0, min: 0, max: 100, 'int': true };
	}

	function effective( attributes, key ) {
		return typeof attributes[ key ] === 'number' ? attributes[ key ] : rule( key )[ 'default' ];
	}

	function text( attributes, key, fallbackKey ) {
		return typeof attributes[ key ] === 'string' ? attributes[ key ] : ( labelDefaults[ fallbackKey ] || '' );
	}

	/**
	 * A RangeControl bound to one schema-governed number.
	 *
	 * Resetting clears the attribute entirely, so the block falls back to the
	 * theme default rather than freezing today's value into the post.
	 */
	function numberControl( attributes, setAttributes, key, label, help ) {
		var spec = rule( key );

		return el( RangeControl, {
			key: key,
			label: label,
			help: help,
			value: effective( attributes, key ),
			min: spec.min,
			max: spec.max,
			step: spec[ 'int' ] ? 1 : 0.05,
			allowReset: true,
			resetFallbackValue: spec[ 'default' ],
			onChange: function ( next ) {
				var update = {};
				update[ key ] = ( next === undefined || next === null ) ? undefined : next;
				setAttributes( update );
			}
		} );
	}

	function labelControl( attributes, setAttributes, key, fallbackKey, label, help ) {
		return el( TextControl, {
			key: key,
			label: label,
			help: help,
			value: text( attributes, key, fallbackKey ),
			onChange: function ( next ) {
				var update = {};
				update[ key ] = next;
				setAttributes( update );
			}
		} );
	}

	/** One blend, in seconds of source — mirrors the canvas's own rounding. */
	function blendSeconds( attributes ) {
		var ratio = effective( attributes, 'blendRatio' );
		var fps = effective( attributes, 'sourceFps' );

		return ( ratio / fps ).toFixed( ratio % fps ? 1 : 0 );
	}

	function timelineText( attributes ) {
		return text( attributes, 'timelineLabel', 'timeline' )
			.replace( '{seconds}', blendSeconds( attributes ) )
			.replace( '{ratio}', effective( attributes, 'blendRatio' ) )
			.replace( '{srcFps}', effective( attributes, 'sourceFps' ) );
	}

	/** What the status line will read once playback starts. */
	function statusPreview( attributes ) {
		var playing = text( attributes, 'playingLabel', 'playing' );
		var total = effective( attributes, 'outputCount' );

		if ( ! playing ) {
			return '';
		}

		if ( /\{(index|total)\}/.test( playing ) ) {
			return playing.replace( '{index}', 1 ).replace( '{total}', total );
		}

		return attributes.showPlayingCount !== false ? playing + ' 1 / ' + total : playing;
	}

	function schematic( attributes ) {
		var ratio = effective( attributes, 'blendRatio' );
		var outputs = effective( attributes, 'outputCount' );
		var strip = [];
		var outs = [];
		var segments = [];
		var i;

		for ( i = 0; i < 4; i++ ) {
			strip.push( el( 'span', { key: 'src' + i, className: 'll-machine-editor__frame' } ) );
		}

		for ( i = 0; i < Math.min( outputs, 10 ); i++ ) {
			outs.push( el( 'span', { key: 'out' + i, className: 'll-machine-editor__frame is-output' } ) );
		}

		for ( i = 0; i < Math.min( outputs, 10 ); i++ ) {
			segments.push( el( 'span', { key: 'seg' + i, className: 'll-machine-editor__segment' } ) );
		}

		var sourceLabel = text( attributes, 'sourceLabel', 'source' );
		var outputLabel = text( attributes, 'outputLabel', 'output' );
		var timeline = timelineText( attributes );
		var status = statusPreview( attributes );

		return el(
			'div',
			{ className: 'll-machine-editor' },
			el(
				'div',
				{ className: 'll-machine-editor__cols' },
				el(
					'div',
					{ className: 'll-machine-editor__col' },
					sourceLabel ? el( 'span', { className: 'll-machine-editor__label' }, sourceLabel ) : null,
					el( 'span', { className: 'll-machine-editor__row' }, strip ),
					outputLabel ? el( 'span', { className: 'll-machine-editor__label' }, outputLabel ) : null,
					el( 'span', { className: 'll-machine-editor__row' }, outs )
				),
				el( 'span', { className: 'll-machine-editor__stage' }, ratio + '→1' )
			),
			attributes.showTimeline !== false
				? el(
					'div',
					{ className: 'll-machine-editor__timeline' },
					el(
						'div',
						{ className: 'll-machine-editor__labels' },
						el( 'span', { className: 'll-machine-editor__label' }, timeline ),
						el( 'span', { className: 'll-machine-editor__label is-status' }, status )
					),
					el( 'span', { className: 'll-machine-editor__bar' }, segments )
				)
				: ( status
					? el(
						'div',
						{ className: 'll-machine-editor__labels is-alone' },
						el( 'span', { className: 'll-machine-editor__label is-status' }, status )
					)
					: null ),
			el( 'span', { className: 'll-machine-editor__hint' }, __( 'The live machine runs on the front end', 'letslapse' ) )
		);
	}

	function inspector( attributes, setAttributes ) {
		return el(
			InspectorControls,
			null,
			el(
				PanelBody,
				{ title: __( 'Copy', 'letslapse' ), initialOpen: true },
				labelControl( attributes, setAttributes, 'sourceLabel', 'source', __( 'Source row', 'letslapse' ) ),
				labelControl( attributes, setAttributes, 'outputLabel', 'output', __( 'Output row', 'letslapse' ) ),
				labelControl( attributes, setAttributes, 'timelineLabel', 'timeline', __( 'Timeline row', 'letslapse' ), __( 'Tokens: {seconds}, {ratio}, {srcFps}.', 'letslapse' ) ),
				labelControl( attributes, setAttributes, 'replayLabel', 'replay', __( 'Replay button', 'letslapse' ) ),
				labelControl( attributes, setAttributes, 'stackingLabel', 'stacking', __( 'Status while stacking', 'letslapse' ), __( 'Tokens: {stacked}, {ratio}, {blend}, {outputs}.', 'letslapse' ) ),
				labelControl( attributes, setAttributes, 'playingLabel', 'playing', __( 'Status while playing', 'letslapse' ), __( 'The counter below is appended automatically. For a different order, place {index} and {total} yourself.', 'letslapse' ) ),
				labelControl( attributes, setAttributes, 'resettingLabel', 'resetting', __( 'Status while restarting', 'letslapse' ) ),
				labelControl( attributes, setAttributes, 'reducedMotionLabel', 'reduced', __( 'Reduced-motion note', 'letslapse' ) ),
				el( 'p', { className: 'll-machine-editor__note' }, __( 'Clear any field to hide that label.', 'letslapse' ) )
			),
			el(
				PanelBody,
				{ title: __( 'Display', 'letslapse' ), initialOpen: true },
				el( ToggleControl, {
					label: __( 'Show the timeline row', 'letslapse' ),
					help: __( 'The bar under the machine that fills as each blend is built.', 'letslapse' ),
					checked: attributes.showTimeline !== false,
					onChange: function ( next ) {
						setAttributes( { showTimeline: next } );
					}
				} ),
				el( ToggleControl, {
					label: __( 'Show the blend counter', 'letslapse' ),
					help: __( 'Appends "1 / 8" to the status while playing.', 'letslapse' ),
					checked: attributes.showPlayingCount !== false,
					onChange: function ( next ) {
						setAttributes( { showPlayingCount: next } );
					}
				} )
			),
			el(
				PanelBody,
				{ title: __( 'Blend', 'letslapse' ), initialOpen: false },
				numberControl( attributes, setAttributes, 'blendRatio', __( 'Source frames per blend', 'letslapse' ), __( 'Each frame lands at 1/N opacity, so this many frames average into one output.', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'outputCount', __( 'Blended frames produced', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'sourceFps', __( 'Source capture rate (fps)', 'letslapse' ), __( 'Only used for the labels — it states what the footage was shot at.', 'letslapse' ) )
			),
			el(
				PanelBody,
				{ title: __( 'Pacing', 'letslapse' ), initialOpen: false },
				numberControl( attributes, setAttributes, 'startRate', __( 'Start rate (frames/s)', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'accel', __( 'Acceleration per blend', 'letslapse' ), __( 'rate(n) = min(max rate, start rate × accel^n)', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'maxRate', __( 'Maximum rate (frames/s)', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'playFps', __( 'Playback rate (fps)', 'letslapse' ) )
			),
			el(
				PanelBody,
				{ title: __( 'Footage', 'letslapse' ), initialOpen: false },
				el(
					MediaUploadCheck,
					null,
					el( MediaUpload, {
						allowedTypes: [ 'image' ],
						value: attributes.atlasId || 0,
						onSelect: function ( media ) {
							setAttributes( { atlasId: media.id, atlasUrl: media.url } );
						},
						render: function ( picker ) {
							return el(
								Fragment,
								null,
								el( Button, {
									variant: 'secondary',
									onClick: picker.open
								}, attributes.atlasId ? __( 'Replace sprite sheet', 'letslapse' ) : __( 'Choose sprite sheet', 'letslapse' ) ),
								attributes.atlasId ? el( Button, {
									variant: 'tertiary',
									isDestructive: true,
									onClick: function () {
										setAttributes( { atlasId: 0, atlasUrl: '' } );
									}
								}, __( 'Use theme default', 'letslapse' ) ) : null
							);
						}
					} )
				),
				el( 'p', { className: 'll-machine-editor__note' }, __( 'A square grid of square frames, read left to right, top to bottom.', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'atlasCols', __( 'Columns in the sheet', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'frameCount', __( 'Frames to use', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'atlasFrameSize', __( 'Frame size (px)', 'letslapse' ) )
			)
		);
	}

	function Edit( props ) {
		var blockProps = useBlockProps( { className: 'll-machine' } );

		return el(
			Fragment,
			null,
			inspector( props.attributes, props.setAttributes ),
			el( 'div', blockProps, schematic( props.attributes ) )
		);
	}

	wp.blocks.registerBlockType( 'letslapse/hero-machine', {
		edit: Edit,
		save: function () {
			return null;
		}
	} );
}( window.wp ) );
