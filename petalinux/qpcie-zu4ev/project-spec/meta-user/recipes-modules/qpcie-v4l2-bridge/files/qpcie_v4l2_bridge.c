// SPDX-License-Identifier: GPL-2.0
/*
 * QPCIe Card-Side V4L2 Bridge Driver
 *
 * Provides a master struct v4l2_device and media_device to bind the
 * official Xilinx HDMI RX Subsystem (xilinx-hdmirxss.c) without requiring
 * Xilinx Video IP Pipeline (xilinx-vipp.c) or frame buffer write (v_frmbuf_wr).
 *
 * This allows official HDMI RX driver to initialize Video PHY, manage EDID/HDCP,
 * detect cable events, and instantiate /dev/v4l-subdev0 for user applications.
 */

#include <linux/module.h>
#include <linux/platform_device.h>
#include <linux/of.h>
#include <linux/of_platform.h>
#include <media/v4l2-device.h>
#include <media/v4l2-async.h>
#include <media/v4l2-subdev.h>
#include <media/media-device.h>

#define DRIVER_NAME "qpcie-v4l2-bridge"

struct qpcie_v4l2_bridge {
	struct device *dev;
	struct media_device media_dev;
	struct v4l2_device v4l2_dev;
	struct v4l2_async_notifier notifier;
	struct v4l2_subdev *hdmirx_sd;
	struct device_node *hdmirx_node;
};

static int qpcie_bridge_notify_bound(struct v4l2_async_notifier *notifier,
				     struct v4l2_subdev *subdev,
				     struct v4l2_async_subdev *asd)
{
	struct qpcie_v4l2_bridge *bridge =
		container_of(notifier, struct qpcie_v4l2_bridge, notifier);

	dev_info(bridge->dev, "HDMI RX subdevice '%s' bound to QPCIe V4L2 bridge\n",
		 subdev->name);
	bridge->hdmirx_sd = subdev;
	return 0;
}

static void qpcie_bridge_notify_unbind(struct v4l2_async_notifier *notifier,
				       struct v4l2_subdev *subdev,
				       struct v4l2_async_subdev *asd)
{
	struct qpcie_v4l2_bridge *bridge =
		container_of(notifier, struct qpcie_v4l2_bridge, notifier);

	dev_info(bridge->dev, "HDMI RX subdevice '%s' unbound from bridge\n",
		 subdev->name);
	bridge->hdmirx_sd = NULL;
}

static int qpcie_bridge_notify_complete(struct v4l2_async_notifier *notifier)
{
	struct qpcie_v4l2_bridge *bridge =
		container_of(notifier, struct qpcie_v4l2_bridge, notifier);
	int ret;

	/* Register character device node (/dev/v4l-subdevX) */
	ret = v4l2_device_register_subdev_nodes(&bridge->v4l2_dev);
	if (ret < 0) {
		dev_err(bridge->dev, "Failed to register subdev nodes: %d\n", ret);
		return ret;
	}

	/* Register media controller (/dev/mediaX) */
	ret = media_device_register(&bridge->media_dev);
	if (ret < 0) {
		dev_err(bridge->dev, "Failed to register media device: %d\n", ret);
		return ret;
	}

	dev_info(bridge->dev,
		 "QPCIe V4L2 Bridge ready: /dev/v4l-subdev* and /dev/media* registered!\n");
	return 0;
}

static const struct v4l2_async_notifier_operations qpcie_bridge_notify_ops = {
	.bound = qpcie_bridge_notify_bound,
	.unbind = qpcie_bridge_notify_unbind,
	.complete = qpcie_bridge_notify_complete,
};

static int qpcie_v4l2_bridge_probe(struct platform_device *pdev)
{
	struct qpcie_v4l2_bridge *bridge;
	struct v4l2_async_subdev *asd;
	struct device_node *np = NULL;
	int ret;

	bridge = devm_kzalloc(&pdev->dev, sizeof(*bridge), GFP_KERNEL);
	if (!bridge)
		return -ENOMEM;

	bridge->dev = &pdev->dev;
	platform_set_drvdata(pdev, bridge);

	/* 1. Find HDMI RX node from DTS phandle or compatible string */
	if (pdev->dev.of_node)
		np = of_parse_phandle(pdev->dev.of_node, "hdmirx", 0);

	if (!np)
		np = of_find_compatible_node(NULL, NULL, "xlnx,v-hdmi-rx-ss-3.2");
	if (!np)
		np = of_find_compatible_node(NULL, NULL, "xlnx,v-hdmi-rx-ss-3.1");

	if (!np) {
		dev_warn(bridge->dev, "No v_hdmi_rx_ss node found in device tree\n");
		return -EPROBE_DEFER;
	}
	bridge->hdmirx_node = np;

	/* 2. Initialize media controller */
	bridge->media_dev.dev = bridge->dev;
	strscpy(bridge->media_dev.model, "QPCIe Card HDMI RX",
		sizeof(bridge->media_dev.model));
	bridge->media_dev.hw_revision = 1;
	media_device_init(&bridge->media_dev);

	/* 3. Initialize V4L2 device */
	bridge->v4l2_dev.mdev = &bridge->media_dev;
	strscpy(bridge->v4l2_dev.name, "qpcie-v4l2", sizeof(bridge->v4l2_dev.name));
	ret = v4l2_device_register(bridge->dev, &bridge->v4l2_dev);
	if (ret < 0) {
		dev_err(bridge->dev, "Failed to register v4l2_device: %d\n", ret);
		media_device_cleanup(&bridge->media_dev);
		of_node_put(np);
		return ret;
	}

	/* 4. Initialize async notifier to wait for xilinx-hdmirxss */
	v4l2_async_nf_init(&bridge->notifier);
	bridge->notifier.ops = &qpcie_bridge_notify_ops;

	asd = v4l2_async_nf_add_fwnode(&bridge->notifier, of_fwnode_handle(np),
				       struct v4l2_async_subdev);
	if (IS_ERR(asd)) {
		ret = PTR_ERR(asd);
		dev_err(bridge->dev, "Failed to add hdmirx fwnode to notifier: %d\n", ret);
		goto err_v4l2;
	}

	ret = v4l2_async_nf_register(&bridge->v4l2_dev, &bridge->notifier);
	if (ret < 0) {
		dev_err(bridge->dev, "Failed to register async notifier: %d\n", ret);
		goto err_nf;
	}

	dev_info(bridge->dev,
		 "QPCIe V4L2 Bridge initialized, waiting for HDMI RX subdevice...\n");
	return 0;

err_nf:
	v4l2_async_nf_cleanup(&bridge->notifier);
err_v4l2:
	v4l2_device_unregister(&bridge->v4l2_dev);
	media_device_cleanup(&bridge->media_dev);
	of_node_put(np);
	return ret;
}

static int qpcie_v4l2_bridge_remove(struct platform_device *pdev)
{
	struct qpcie_v4l2_bridge *bridge = platform_get_drvdata(pdev);

	v4l2_async_nf_unregister(&bridge->notifier);
	v4l2_async_nf_cleanup(&bridge->notifier);

	if (media_devnode_is_registered(bridge->media_dev.devnode))
		media_device_unregister(&bridge->media_dev);
	media_device_cleanup(&bridge->media_dev);

	v4l2_device_unregister(&bridge->v4l2_dev);

	if (bridge->hdmirx_node)
		of_node_put(bridge->hdmirx_node);

	dev_info(&pdev->dev, "QPCIe V4L2 Bridge unloaded\n");
	return 0;
}

static const struct of_device_id qpcie_v4l2_bridge_of_match[] = {
	{ .compatible = "yuan,qpcie-v4l2-bridge", },
	{ /* sentinel */ }
};
MODULE_DEVICE_TABLE(of, qpcie_v4l2_bridge_of_match);

static struct platform_driver qpcie_v4l2_bridge_driver = {
	.probe = qpcie_v4l2_bridge_probe,
	.remove = qpcie_v4l2_bridge_remove,
	.driver = {
		.name = DRIVER_NAME,
		.of_match_table = qpcie_v4l2_bridge_of_match,
	},
};

static struct platform_device *qpcie_v4l2_bridge_pdev;

static int __init qpcie_v4l2_bridge_init(void)
{
	int ret;

	ret = platform_driver_register(&qpcie_v4l2_bridge_driver);
	if (ret)
		return ret;

	/* If not instantiated by DT, register virtual platform device */
	qpcie_v4l2_bridge_pdev = platform_device_register_simple(DRIVER_NAME, -1, NULL, 0);
	if (IS_ERR(qpcie_v4l2_bridge_pdev)) {
		pr_debug(DRIVER_NAME ": virtual platform_device register returned %ld\n",
			 PTR_ERR(qpcie_v4l2_bridge_pdev));
		qpcie_v4l2_bridge_pdev = NULL;
	}

	return 0;
}

static void __exit qpcie_v4l2_bridge_exit(void)
{
	if (qpcie_v4l2_bridge_pdev)
		platform_device_unregister(qpcie_v4l2_bridge_pdev);
	platform_driver_unregister(&qpcie_v4l2_bridge_driver);
}

module_init(qpcie_v4l2_bridge_init);
module_exit(qpcie_v4l2_bridge_exit);

MODULE_AUTHOR("QPCIe Development Team");
MODULE_DESCRIPTION("QPCIe Card-Side V4L2 Bridge for Xilinx HDMI RX Subsystem");
MODULE_LICENSE("GPL v2");
