/* SPDX-License-Identifier: GPL-2.0 */
#ifndef QPCIE_KMS_H
#define QPCIE_KMS_H

struct qpcie_dev;
struct pci_dev;
int qpcie_kms_register(struct qpcie_dev *qdev);
int qpcie_kms_protect(struct qpcie_dev *qdev);
void qpcie_kms_remove(struct qpcie_dev *qdev);
void qpcie_kms_reset_prepare(struct pci_dev *pdev);
void qpcie_kms_frame_irq(struct qpcie_dev *qdev);
void qpcie_kms_capture_fault(struct qpcie_dev *qdev);
#endif
