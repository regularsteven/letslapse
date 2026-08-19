/**
 * Rig hero — editor.
 *
 * No build step: plain ES5 against the wp.* globals, so the theme is
 * installable as-is. The editor draws the real markup with the real stylesheet
 * and the real SVG — the same one render.php inlines, handed over on
 * window.letsLapseRig — so the preview cannot drift from the front end. It
 * replays whenever a motion setting changes, and on the replay control, by
 * remounting the mark.
 */
( function ( wp ) {
	'use strict';

	if ( ! wp || ! wp.blocks || ! wp.element ) {
		return;
	}

	var el = wp.element.createElement;
	var Fragment = wp.element.Fragment;
	var useState = wp.element.useState;
	var __ = wp.i18n.__;
	var blockEditor = wp.blockEditor;
	var components = wp.components;

	var useBlockProps = blockEditor.useBlockProps;
	var useInnerBlocksProps = blockEditor.useInnerBlocksProps || blockEditor.__experimentalUseInnerBlocksProps;
	var InnerBlocks = blockEditor.InnerBlocks;
	var InspectorControls = blockEditor.InspectorControls;
	var MediaUpload = blockEditor.MediaUpload;
	var MediaUploadCheck = blockEditor.MediaUploadCheck;

	var PanelBody = components.PanelBody;
	var RangeControl = components.RangeControl;
	var SelectControl = components.SelectControl;
	var ToggleControl = components.ToggleControl;
	var TextControl = components.TextControl;
	var Button = components.Button;
	var FocalPointPicker = components.FocalPointPicker;

	var data = window.letsLapseRig || {};
	var schema = data.schema || {};
	var labelDefaults = data.labelDefaults || {};
	var MARK = data.mark || '';

	var TEMPLATE = [
		[ 'core/heading', { level: 1, className: 'is-style-ll-display', placeholder: __( 'Headline', 'letslapse' ) } ],
		[ 'core/paragraph', { className: 'is-style-ll-standfirst', placeholder: __( 'One line on what it does.', 'letslapse' ) } ]
	];

	function rule( key ) {
		return schema[ key ] || { 'default': 0, min: 0, max: 100, 'int': true };
	}

	function effective( attributes, key ) {
		return typeof attributes[ key ] === 'number' ? attributes[ key ] : rule( key )[ 'default' ];
	}

	/** Where the photo is cropped around, as a CSS object-position. */
	function objectPosition( attributes ) {
		var focal = attributes.focalPoint || {};
		var x = typeof focal.x === 'number' ? focal.x : 0.5;
		var y = typeof focal.y === 'number' ? focal.y : 0.5;

		return Math.round( x * 10000 ) / 100 + '% ' + Math.round( y * 10000 ) / 100 + '%';
	}

	/** The mark's default alt text follows the variant until someone sets one. */
	function markLabel( attributes ) {
		if ( typeof attributes.markLabel === 'string' ) {
			return attributes.markLabel;
		}

		return labelDefaults[ attributes.variant === 'loop' ? 'markLoop' : 'markBuild' ] || '';
	}

	function numberControl( attributes, setAttributes, key, label, help, step ) {
		var spec = rule( key );

		return el( RangeControl, {
			label: label,
			help: help,
			value: effective( attributes, key ),
			min: spec.min,
			max: spec.max,
			step: step || ( spec[ 'int' ] ? 1 : 0.05 ),
			allowReset: true,
			resetFallbackValue: spec[ 'default' ],
			onChange: function ( next ) {
				var update = {};
				update[ key ] = ( next === undefined || next === null ) ? undefined : next;
				setAttributes( update );
			}
		} );
	}

	function photoPanel( attributes, setAttributes ) {
		var url = attributes.backgroundUrl || '';

		return el(
			PanelBody,
			{ title: __( 'Photograph', 'letslapse' ), initialOpen: !! url },
			el(
				MediaUploadCheck,
				null,
				el( MediaUpload, {
					allowedTypes: [ 'image' ],
					value: attributes.backgroundId || 0,
					onSelect: function ( media ) {
						setAttributes( { backgroundId: media.id, backgroundUrl: media.url } );
					},
					render: function ( picker ) {
						return el( Button, {
							variant: 'secondary',
							onClick: picker.open
						}, url ? __( 'Replace photograph', 'letslapse' ) : __( 'Choose a photograph', 'letslapse' ) );
					}
				} )
			),
			url
				? el( Button, {
					variant: 'tertiary',
					isDestructive: true,
					onClick: function () {
						setAttributes( { backgroundId: 0, backgroundUrl: '', focalPoint: undefined } );
					}
				}, __( 'Remove photograph', 'letslapse' ) )
				: el( 'p', { className: 'll-rig-editor__note' }, __( 'Optional. Without one the stage keeps its plain glow.', 'letslapse' ) ),
			url && FocalPointPicker
				? el( FocalPointPicker, {
					label: __( 'Focal point', 'letslapse' ),
					help: __( 'What stays in frame as the hero is cropped.', 'letslapse' ),
					url: url,
					value: attributes.focalPoint || { x: 0.5, y: 0.5 },
					onChange: function ( next ) {
						setAttributes( { focalPoint: next } );
					}
				} )
				: null,
			url
				? numberControl( attributes, setAttributes, 'scrim', __( 'Scrim', 'letslapse' ), __( 'How far the photograph is dimmed under the copy. The rig and the words have to stay legible — that is what this is for.', 'letslapse' ), 0.01 )
				: null
		);
	}

	function inspector( attributes, setAttributes ) {
		return el(
			InspectorControls,
			null,
			el(
				PanelBody,
				{ title: __( 'Animation', 'letslapse' ), initialOpen: true },
				el( SelectControl, {
					label: __( 'What the rig does', 'letslapse' ),
					value: attributes.variant,
					options: [
						{ label: __( 'Build once, then hold', 'letslapse' ), value: 'build' },
						{ label: __( 'Keep running (no end)', 'letslapse' ), value: 'loop' }
					],
					help: attributes.variant === 'loop'
						? __( 'For work with no known end time. Nothing rebuilds — a light runs the body instead.', 'letslapse' )
						: __( 'Assembles in about two seconds on load, then hands over to the copy.', 'letslapse' ),
					onChange: function ( next ) {
						setAttributes( { variant: next } );
					}
				} ),
				numberControl( attributes, setAttributes, 'speed', __( 'Speed', 'letslapse' ), __( '1 is as designed. Lower is slower — the beats keep their proportions either way.', 'letslapse' ) ),
				numberControl( attributes, setAttributes, 'markSize', __( 'Mark size (px)', 'letslapse' ), __( 'Shrinks with the viewport; this is its cap. The board pads stop reading below about 40px.', 'letslapse' ), 4 )
			),
			el(
				PanelBody,
				{ title: __( 'Layout', 'letslapse' ), initialOpen: true },
				el( SelectControl, {
					label: __( 'Arrangement', 'letslapse' ),
					value: attributes.arrangement,
					options: [
						{ label: __( 'Mark above the copy', 'letslapse' ), value: 'stack' },
						{ label: __( 'Mark beside the copy', 'letslapse' ), value: 'inline' }
					],
					onChange: function ( next ) {
						setAttributes( { arrangement: next } );
					}
				} ),
				el( ToggleControl, {
					label: __( 'Stage panel', 'letslapse' ),
					help: __( 'A bordered well with the glow behind the rig. Off puts the rig straight on the page.', 'letslapse' ),
					checked: attributes.showStage !== false,
					onChange: function ( next ) {
						setAttributes( { showStage: next } );
					}
				} )
			),
			photoPanel( attributes, setAttributes ),
			el(
				PanelBody,
				{ title: __( 'Copy', 'letslapse' ), initialOpen: false },
				el( ToggleControl, {
					label: __( 'Show the wordmark', 'letslapse' ),
					checked: attributes.showWordmark !== false,
					onChange: function ( next ) {
						setAttributes( { showWordmark: next } );
					}
				} ),
				attributes.showWordmark !== false
					? el( TextControl, {
						label: __( 'Wordmark', 'letslapse' ),
						value: attributes.wordmarkText,
						onChange: function ( next ) {
							setAttributes( { wordmarkText: next } );
						}
					} )
					: null,
				el( ToggleControl, {
					label: __( 'Show a replay control', 'letslapse' ),
					help: __( 'Appears only for visitors whose browser can actually replay it.', 'letslapse' ),
					checked: !! attributes.showReplay,
					onChange: function ( next ) {
						setAttributes( { showReplay: next } );
					}
				} ),
				attributes.showReplay
					? el( TextControl, {
						label: __( 'Replay button', 'letslapse' ),
						value: attributes.replayLabel,
						onChange: function ( next ) {
							setAttributes( { replayLabel: next } );
						}
					} )
					: null,
				el( TextControl, {
					label: __( 'Mark description', 'letslapse' ),
					help: __( 'Read out by screen readers. Clear it when the copy beside the mark already says this — then the mark is decorative.', 'letslapse' ),
					value: markLabel( attributes ),
					onChange: function ( next ) {
						setAttributes( { markLabel: next } );
					}
				} )
			)
		);
	}

	function Edit( props ) {
		var attributes = props.attributes;
		var replays = useState( 0 );
		var nonce = replays[ 0 ];
		var setNonce = replays[ 1 ];

		var speed = effective( attributes, 'speed' );
		var size = effective( attributes, 'markSize' );

		var classes = [
			'll-rig-hero',
			'll-rig-hero--' + ( attributes.arrangement === 'inline' ? 'inline' : 'stack' )
		];

		if ( attributes.showStage !== false ) {
			classes.push( 'has-stage' );
		}

		var photo = attributes.backgroundUrl || '';

		if ( photo ) {
			classes.push( 'has-photo' );
		}

		var style = {
			'--ll-rig-sp': String( Math.round( ( 1 / speed ) * 1000 ) / 1000 ),
			'--ll-rig-size': size + 'px',
			'--ll-rig-scrim': String( effective( attributes, 'scrim' ) )
		};

		var blockProps = useBlockProps( { className: classes.join( ' ' ), style: style } );
		var innerProps = useInnerBlocksProps(
			{ className: 'll-rig-hero__copy' },
			{ template: TEMPLATE, templateLock: false }
		);

		var wordmark = attributes.showWordmark !== false ? ( attributes.wordmarkText || '' ) : '';

		return el(
			Fragment,
			null,
			inspector( attributes, props.setAttributes ),
			el(
				'div',
				blockProps,
				photo ? el( 'img', {
					className: 'll-rig-hero__photo',
					src: photo,
					alt: '',
					style: { objectPosition: objectPosition( attributes ) }
				} ) : null,
				photo ? el( 'div', { className: 'll-rig-hero__scrim', 'aria-hidden': 'true' } ) : null,
				el(
					'div',
					{ className: 'll-rig-hero__mark' },
					el( 'div', {
						/* Remounting is the restart: new key, new element, animation from zero. */
						key: [ attributes.variant, speed, size, nonce ].join( ':' ),
						className: 'll-rig ll-rig--' + ( attributes.variant === 'loop' ? 'loop' : 'build' ),
						'aria-hidden': 'true',
						dangerouslySetInnerHTML: { __html: MARK }
					} ),
					wordmark ? el( 'p', { className: 'll-rig-hero__wordmark' }, wordmark ) : null,
					el(
						'button',
						{
							type: 'button',
							className: 'll-rig-hero__replay is-editor-replay',
							onClick: function () {
								setNonce( nonce + 1 );
							}
						},
						'↻ ' + ( attributes.showReplay ? ( attributes.replayLabel || __( 'Replay', 'letslapse' ) ) : __( 'Replay (editor only)', 'letslapse' ) )
					)
				),
				el( 'div', innerProps )
			)
		);
	}

	wp.blocks.registerBlockType( 'letslapse/rig-hero', {
		edit: Edit,
		save: function () {
			return el( InnerBlocks.Content );
		}
	} );
}( window.wp ) );
