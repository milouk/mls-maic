// SPDX-License-Identifier: GPL-2.0
/*
 * emdoor,synaptics_dsp - far-field voice DSP glue for the MLS MAIC (Emdoor TS809) board
 *
 * This is a REIMPLEMENTATION. No source for the original exists in any public tree; the
 * only trace of it in the stock kernel is the symbol `synaptics_dsp_event_work`. What the
 * original did was reconstructed from two pieces of hard evidence:
 *
 *  1. The device tree node, which carries no `reg` (so it is a platform device, not an
 *     I2C or SPI client), one interrupt, and seven pinctrl states:
 *
 *        synaptics {
 *            compatible   = "emdoor,synaptics_dsp";
 *            interrupts   = <0x48 0x2>;         // mtk-eint 72, edge triggered
 *            pinctrl-names = "default",
 *                            "dsp_rst_high", "dsp_rst_low",
 *                            "dsp_pwr_high", "dsp_pwr_low",
 *                            "led_pwr_high", "led_pwr_low";
 *        };
 *
 *  2. The live device, where it appears as input device "DSP_IRQ" advertising exactly
 *     two keys: KEY_POWER and KEY_VOICECOMMAND, and where /proc/interrupts shows
 *     "mtk-eint 72 Edge DSP_IRQ".
 *
 * So the hardware is a self-contained wake-word block: it is powered and released from
 * reset over GPIO, it drives an indicator LED rail, and when it recognises speech it
 * raises one edge-triggered interrupt. There is no audio path through this driver -- the
 * microphones themselves are the nau8540 on I2C, which is a separate driver.
 *
 * WHAT IS INFERRED, and should be verified on hardware: the original presumably
 * distinguished a wake-word event (KEY_VOICECOMMAND) from a power/wake event (KEY_POWER),
 * but there is no register interface to read and nothing in the node says how. Since the
 * stock interrupt has fired exactly once since boot, a plausible reading is that the
 * single IRQ means "wake word detected". This driver therefore reports KEY_VOICECOMMAND
 * per interrupt, and declares KEY_POWER so the input device's capability bits match the
 * stock one (userspace that opens it by capability keeps working).
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/interrupt.h>
#include <linux/input.h>
#include <linux/pinctrl/consumer.h>
#include <linux/slab.h>
#include <linux/workqueue.h>
#include <linux/delay.h>

#define DRV_NAME	"synaptics_dsp"
#define INPUT_NAME	"DSP_IRQ"

struct synaptics_dsp {
	struct device		*dev;
	struct input_dev	*input;
	struct pinctrl		*pinctrl;
	struct pinctrl_state	*st_default;
	struct pinctrl_state	*st_rst_high, *st_rst_low;
	struct pinctrl_state	*st_pwr_high, *st_pwr_low;
	struct pinctrl_state	*st_led_high, *st_led_low;
	struct work_struct	event_work;
	int			irq;
};

/* Optional: a missing state is not fatal, boards wire up different subsets. */
static struct pinctrl_state *dsp_state(struct synaptics_dsp *dsp, const char *name)
{
	struct pinctrl_state *s = pinctrl_lookup_state(dsp->pinctrl, name);

	if (IS_ERR(s)) {
		dev_dbg(dsp->dev, "pinctrl state '%s' not present\n", name);
		return NULL;
	}
	return s;
}

static void dsp_select(struct synaptics_dsp *dsp, struct pinctrl_state *s)
{
	if (s)
		pinctrl_select_state(dsp->pinctrl, s);
}

/* Named to match the stock kernel's symbol, which is the one clue to the original. */
static void synaptics_dsp_event_work(struct work_struct *work)
{
	struct synaptics_dsp *dsp = container_of(work, struct synaptics_dsp, event_work);

	input_report_key(dsp->input, KEY_VOICECOMMAND, 1);
	input_sync(dsp->input);
	input_report_key(dsp->input, KEY_VOICECOMMAND, 0);
	input_sync(dsp->input);
}

static irqreturn_t synaptics_dsp_irq(int irq, void *data)
{
	struct synaptics_dsp *dsp = data;

	/* The interrupt is edge triggered and carries no status register to clear, so all
	 * the handler can do is hand the event off; input_report_key may sleep-ish paths
	 * in some configs, so keep it in process context.
	 */
	schedule_work(&dsp->event_work);
	return IRQ_HANDLED;
}

static int synaptics_dsp_power_on(struct synaptics_dsp *dsp)
{
	dsp_select(dsp, dsp->st_default);

	/* Hold in reset, apply power, then release reset. The delays are conservative --
	 * the original's timings are unknown, and this block is only brought up once.
	 */
	dsp_select(dsp, dsp->st_rst_low);
	dsp_select(dsp, dsp->st_pwr_high);
	msleep(20);
	dsp_select(dsp, dsp->st_rst_high);
	msleep(20);

	/* Indicator LED rail: the node exposes it, so the DSP owns it. */
	dsp_select(dsp, dsp->st_led_high);
	return 0;
}

static void synaptics_dsp_power_off(struct synaptics_dsp *dsp)
{
	dsp_select(dsp, dsp->st_led_low);
	dsp_select(dsp, dsp->st_rst_low);
	dsp_select(dsp, dsp->st_pwr_low);
}

static int synaptics_dsp_probe(struct platform_device *pdev)
{
	struct synaptics_dsp *dsp;
	int ret;

	dsp = devm_kzalloc(&pdev->dev, sizeof(*dsp), GFP_KERNEL);
	if (!dsp)
		return -ENOMEM;

	dsp->dev = &pdev->dev;
	platform_set_drvdata(pdev, dsp);
	INIT_WORK(&dsp->event_work, synaptics_dsp_event_work);

	dsp->pinctrl = devm_pinctrl_get(&pdev->dev);
	if (IS_ERR(dsp->pinctrl)) {
		dev_err(&pdev->dev, "no pinctrl\n");
		return PTR_ERR(dsp->pinctrl);
	}
	dsp->st_default  = dsp_state(dsp, "default");
	dsp->st_rst_high = dsp_state(dsp, "dsp_rst_high");
	dsp->st_rst_low  = dsp_state(dsp, "dsp_rst_low");
	dsp->st_pwr_high = dsp_state(dsp, "dsp_pwr_high");
	dsp->st_pwr_low  = dsp_state(dsp, "dsp_pwr_low");
	dsp->st_led_high = dsp_state(dsp, "led_pwr_high");
	dsp->st_led_low  = dsp_state(dsp, "led_pwr_low");

	dsp->input = devm_input_allocate_device(&pdev->dev);
	if (!dsp->input)
		return -ENOMEM;

	dsp->input->name = INPUT_NAME;
	dsp->input->dev.parent = &pdev->dev;
	/* Same capability bits the stock device advertises. */
	input_set_capability(dsp->input, EV_KEY, KEY_VOICECOMMAND);
	input_set_capability(dsp->input, EV_KEY, KEY_POWER);

	ret = input_register_device(dsp->input);
	if (ret) {
		dev_err(&pdev->dev, "input_register_device: %d\n", ret);
		return ret;
	}

	synaptics_dsp_power_on(dsp);

	dsp->irq = platform_get_irq(pdev, 0);
	if (dsp->irq < 0) {
		dev_err(&pdev->dev, "no irq in DT\n");
		ret = dsp->irq;
		goto err_power;
	}

	ret = devm_request_irq(&pdev->dev, dsp->irq, synaptics_dsp_irq,
			       IRQF_TRIGGER_RISING, INPUT_NAME, dsp);
	if (ret) {
		dev_err(&pdev->dev, "request_irq %d: %d\n", dsp->irq, ret);
		goto err_power;
	}

	dev_info(&pdev->dev, "voice DSP ready (irq %d)\n", dsp->irq);
	return 0;

err_power:
	synaptics_dsp_power_off(dsp);
	return ret;
}

static int synaptics_dsp_remove(struct platform_device *pdev)
{
	struct synaptics_dsp *dsp = platform_get_drvdata(pdev);

	cancel_work_sync(&dsp->event_work);
	synaptics_dsp_power_off(dsp);
	return 0;
}

static const struct of_device_id synaptics_dsp_of_match[] = {
	{ .compatible = "emdoor,synaptics_dsp", },
	{ },
};
MODULE_DEVICE_TABLE(of, synaptics_dsp_of_match);

static struct platform_driver synaptics_dsp_driver = {
	.probe	= synaptics_dsp_probe,
	.remove	= synaptics_dsp_remove,
	.driver	= {
		.name		= DRV_NAME,
		.of_match_table	= synaptics_dsp_of_match,
	},
};
module_platform_driver(synaptics_dsp_driver);

MODULE_DESCRIPTION("Emdoor/Synaptics far-field voice DSP glue (MAIC)");
MODULE_LICENSE("GPL v2");
