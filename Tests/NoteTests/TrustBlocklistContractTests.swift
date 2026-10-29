// Copyright (c) 2026 Pingolin LLC
//
// This file is part of Pingolin Note.
//
// Pingolin Note is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Pingolin Note is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Pingolin Note. If not, see <https://www.gnu.org/licenses/>.

import CryptoKit
import Security
import XCTest
@testable import Note

/// The leaked-key check against the shared trust vectors that every Pingolin client must agree with;
/// their certificates, paths and verdicts are carried here. The 49 public certificates
/// (Fixtures/trust-contract holds them as DER, each file checked against its certificate SHA-256) are
/// each read to the key the vectors list for it. The 30 paths each get the listed verdict: refused when
/// a certificate in the path carries one of the nine keys, accepted otherwise. Among them:
/// - AAA Certificate Services in a path with no leaked key, accepted (A6, A7);
/// - an emSign path under the G1 root, which is not on the list, accepted (A8);
/// - the ECDSA twin of a leaked certificate, another fingerprint over the same key, refused (R3, L2);
/// - the emSign ECC Root CA - G3 key with no leaked intermediate, refused (R4).
final class TrustBlocklistContractTests: XCTestCase {

    private func certificate(_ name: String) throws -> SecCertificate {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/trust-contract/\(name).der")
        return try XCTUnwrap(SecCertificateCreateWithData(nil, try Data(contentsOf: url) as CFData), name)
    }

    /// Each file: the SHA-256 of the certificate itself and of its SubjectPublicKeyInfo, lower-case hex.
    private let files: [String: (certificate: String, key: String)] = [
        "accept-SSL.com_TLS_Issuing_ECC_CA_R2-by-AAA":
            ("2dc7ddc440b6332274868c5e1df5d15bd71e5a1861d22b6181bc1c2cbfa32b34",
             "34f46b064f7ab7ae2f6b2f376bc29fee42d5f1599d8bfd7b420a5eb37dbcfcf9"),
        "accept-SSL.com_TLS_Issuing_ECC_CA_R2-by-SSL.com_TLS_ECC_Root_CA_2022":
            ("7f3ee6366236ede6c1f7c21c443c644d32153edaa9357c3a6da879cdf2a6b0b6",
             "34f46b064f7ab7ae2f6b2f376bc29fee42d5f1599d8bfd7b420a5eb37dbcfcf9"),
        "accept-SSL.com_TLS_Issuing_RSA_CA_R1-by-AAA":
            ("ab3de819f342f0a61d199d4be86a4f7f3f2810cdff0b0bff872f4d93e812ce80",
             "d052815719f277826af2ff124fedec8cef96a01ecf2c112949d8b16c71352f88"),
        "accept-SSL.com_TLS_Issuing_RSA_CA_R1-by-SSL.com_TLS_RSA_Root_CA_2022":
            ("bfbc39e9fa2b84c9a92337e2344ee2381d8d3d3ae8ea75ef4e48e5807ed80c69",
             "d052815719f277826af2ff124fedec8cef96a01ecf2c112949d8b16c71352f88"),
        "accept-SSL.com_TLS_Transit_ECC_CA_R2-by-AAA":
            ("fe9fb0f783ebb843109aa31de9da9864b6542940c307df23180b11f1f7e108de",
             "397ca3f6781ba8ef5c8cb78effeb7d1a097610fe094e75561eae0b13084533dc"),
        "accept-SSL.com_TLS_Transit_ECC_CA_R2-by-SSL.com_TLS_ECC_Root_CA_2022":
            ("5d1bc399274e649e1c72697de91a54ad725088c5221cb61e17ee9c290bc42a92",
             "397ca3f6781ba8ef5c8cb78effeb7d1a097610fe094e75561eae0b13084533dc"),
        "accept-SSL.com_TLS_Transit_RSA_CA_R2-by-AAA":
            ("ebd417f595c3f259b7455c8135293505b692c47e0f74d3ba885ce22c8875ca28",
             "be7d1ed431296039ce59e3521f4224bafad2f2220013bc79681ec4a250d4c52d"),
        "accept-SSL.com_TLS_Transit_RSA_CA_R2-by-SSL.com_TLS_RSA_Root_CA_2022":
            ("ffe930442dfeb69ce29a908b6a639b370bd6ba6075f931ab83561d938b453a21",
             "be7d1ed431296039ce59e3521f4224bafad2f2220013bc79681ec4a250d4c52d"),
        "accept-USERTrust_RSA_Certification_Authority-by-AAA":
            ("68b9c761219a5b1f0131784474665db61bbdb109e00f05ca9f74244ee5f5f52b",
             "c784333d20bcd742b9fdc3236f4e509b8937070e73067e254dd3bf9c45bf4dde"),
        "accept-emSign_SSL_CA_G1-by-emSign_Root_CA_G1":
            ("47b2efbc3670e7db4b41f22c51fc02ee84fb2dbf3082a49f2c2688122e9210a1",
             "aafccd83af8f4bb25b08547e14bf9e01f1593a237aa575ec1f5b5cf5ab87945f"),
        "accept-gts-1-leaf-pingolindev.com":
            ("62e0cdf9edfa9b66f401c2fd16ce67947072bbeb23e6a7e6846e6f112771b774",
             "fcb2c51ef4221f9f31e0623ae8351e82e68432b7aca8ce18ce3c7a5013ed9944"),
        "accept-gts-2-WE1":
            ("1dfc1605fbad358d8bc844f76d15203fac9ca5c1a79fd4857ffaf2864fbebf96",
             "908769e8d34477cc2cba0632c88605b22d7294c0840f78596d247c645b1afc0e"),
        "accept-gts-3-GTS_Root_R4-by-GlobalSign_Root_CA":
            ("76b27b80a58027dc3cf1da68dac17010ed93997d0b603e2fadbe85012493b5a7",
             "9847e5653e5e9e847516e5cb818606aa7544a19be67fd7366d506988e8d84347"),
        "accept-le-x1-1-leaf-valid-isrgrootx1.letsencrypt.org":
            ("59b8cdebe5515befe2f0f293f0833bffe475353479b407b6dc65b4f2dbddef31",
             "31a1c70fb6b38babc9a5e15ea281a2f135cbde563bcbce93e9130fc62e8bc6c2"),
        "accept-le-x1-2-YR2":
            ("238b85a0099c65b970477d5724f1a1d475ce5058cffe4efa8733899bdb863c47",
             "9d637b3d27a9e570d07607b9ccadb80a70915c7af72afce12841b1b1da825fd1"),
        "accept-le-x1-3-Root_YR-by-ISRG_Root_X1":
            ("072639d0b140d5bffae16ad9c3f6cc6086040621f51ee61a6d46a8915c07cf76",
             "7e4e8838a8add6295de7ae3b047d3aba3488ab95db0a0aa56d897a00d8618bcf"),
        "accept-le-x2-1-leaf-valid-isrgrootx2.letsencrypt.org":
            ("ef94c75ba11ed3ffae7ae7d7833dd91d7712420755113e6487400ddbde1a8b87",
             "77f9261fb8ee872085ce454ddffdfd086df489ca56d8ec5327b49ecb11e0658f"),
        "accept-le-x2-2-YE1":
            ("a2372d06431e9716365eeed47ec020351497d182fcc038e457e58168a03cac07",
             "6ebcefb4210b088654a38b03fea3d7d1c711b4fb1ddc363a45f9b1a4e53da01e"),
        "accept-le-x2-3-Root_YE-by-ISRG_Root_X2":
            ("0fc0901cca2bae9e9fdbb02d50d02f1094f7b36672086991b9e897626dc485f0",
             "b0292ae545978e0fbb98abbd94c861605e5b18bb32ed523f50d5b7b5c71d47bc"),
        "accept-sectigo-1-leaf-sectigo.com":
            ("b77c199d491ae95749fde04bbae58e1d2c9e675376976f105c45b0d12ad875ca",
             "b56b7930e07522ce3f1deff55d4ba24f4c7ee9ed15d938924f82d44829c9334b"),
        "accept-sectigo-2-Sectigo_Public_Server_Authentication_CA_OV_R36":
            ("6542d176bed50f193c0ce297ae44ecd8a0a86bec2ede682769344059b4e78530",
             "2aa918617e4b60060fed719e9aacdbb4f3c803cc7b052fc16ce21c0177f78f69"),
        "accept-sectigo-3-Sectigo_R46-by-USERTrust_RSA":
            ("92f351bf3d54164dfa8dd8f9e1139d3150349786485d2b9eecd00e2971c1e6c5",
             "0e8bb18bbeefb381be21bfc1a206d317298462ad104855f04a0542699708d3d4"),
        "accept-sectigo-4-USERTrust_RSA_Certification_Authority":
            ("e793c9b02fd8aa13e21c31228accb08119643b749c898964b1746d46c3d4cbd2",
             "c784333d20bcd742b9fdc3236f4e509b8937070e73067e254dd3bf9c45bf4dde"),
        "leaked-EM_DV_TLS_CA_G3B-by-AAA":
            ("45a883f349aedfd5f3a649b5498ffb121712ba8b448f3f2a91dbc5a766fcddbe",
             "ebed6475c2c2d80fcb199f3fe8dd6e6b3ce60b77eb15d4e42c3dec0c6f5b5105"),
        "leaked-EM_DV_TLS_CA_G3B-by-emSign_G3":
            ("42c4accd12c4f59597925e1a08a7a90102608543809308d50ec427e118ba1493",
             "ebed6475c2c2d80fcb199f3fe8dd6e6b3ce60b77eb15d4e42c3dec0c6f5b5105"),
        "leaked-EM_DV_TLS_CA_G3B-by-emSign_G3-ecdsa-twin":
            ("37e866582d43c35d7c17d47794b974f291b3047b868dc123382477f7a08aefa8",
             "ebed6475c2c2d80fcb199f3fe8dd6e6b3ce60b77eb15d4e42c3dec0c6f5b5105"),
        "leaked-EM_DV_TLS_CA_G3C-by-AAA":
            ("62b7f9868263f72f6911fc78ceaf72c1979158b7368bf648683bb2aa39b02e72",
             "49dd353dc2b919a3770645117d0e60c16115e7d1bc259eefe734b00ea434fe5f"),
        "leaked-EM_DV_TLS_CA_G3C-by-emSign_G3":
            ("0164d7ceae5bb909c272af151ff44b1177ae9b47d9424b94f1d9558c30934d19",
             "49dd353dc2b919a3770645117d0e60c16115e7d1bc259eefe734b00ea434fe5f"),
        "leaked-EM_EV_TLS_CA_G3B-by-AAA":
            ("579480aea166290bd3c643589e795fc0d0e54e86505d180f1dff99efd3199512",
             "e0254c7fcdc265e2f0f8a428dabb75ab4ae039b4872d62f5ee57f0877d5a8a41"),
        "leaked-EM_EV_TLS_CA_G3B-by-emSign_G3":
            ("e7568fe6e12331f4fd7de61da4c7559d0f8eb192a218d4741a3ba75184333838",
             "e0254c7fcdc265e2f0f8a428dabb75ab4ae039b4872d62f5ee57f0877d5a8a41"),
        "leaked-EM_EV_TLS_CA_G3C-by-AAA":
            ("fd9d5c2dbbd4995ab69b8d50c439d9527b00529199c2fd01b2174eb58f07021f",
             "5c0660a2b164910d8ff589c18e14552e9e0ec237dcefe2cb736d41a4811f81a0"),
        "leaked-EM_EV_TLS_CA_G3C-by-emSign_G3":
            ("432ec25f0d28de9006d97bf752f17bbb2cd41f669933fcb072d9a1148d0261f3",
             "5c0660a2b164910d8ff589c18e14552e9e0ec237dcefe2cb736d41a4811f81a0"),
        "leaked-EM_OV_CS_CA_G3B-by-AAA":
            ("a496e23ac0cab8155fc9b117b97eae368efcbb9041aec8804d5a308d2d01c2d8",
             "ec4ffa1ad0ac88081314b7aaffef6a91f97cd57291bb5ba686c5415f5eb4f6b6"),
        "leaked-EM_OV_CS_CA_G3B-by-emSign_G3":
            ("9e39de2881273acc225a149c72ba3e0f51424963669ab633ee1dc7df5db067b4",
             "ec4ffa1ad0ac88081314b7aaffef6a91f97cd57291bb5ba686c5415f5eb4f6b6"),
        "leaked-EM_OV_CS_CA_G3C-by-AAA":
            ("84112972b8e59d14560ae7e7119654474aad119990cf3722bfc1e3b91615e1fd",
             "92c063d67e8f14db71d288e11266ffdaf69cbf115f7bab14f3bc2f68d25e0e30"),
        "leaked-EM_OV_CS_CA_G3C-by-emSign_G3":
            ("4b2460a466f95fd40113bcdcca2ceb29b3b093921de45474da7df48874c630b1",
             "92c063d67e8f14db71d288e11266ffdaf69cbf115f7bab14f3bc2f68d25e0e30"),
        "leaked-EM_OV_TLS_CA_G3B-by-AAA":
            ("5f1ded4dd590af74631290cf073b122a2aac6a1fa479778a0bd43579bd832699",
             "43bffa19d6ef651451f6841e019931e96f6f2eaeff28ab4b6f1ce4576de2717b"),
        "leaked-EM_OV_TLS_CA_G3B-by-emSign_G3":
            ("98b896625c0c230adeec3eb2cf6aad5001ecf9156a68644e82374ce5833bc25b",
             "43bffa19d6ef651451f6841e019931e96f6f2eaeff28ab4b6f1ce4576de2717b"),
        "leaked-EM_OV_TLS_CA_G3C-by-AAA":
            ("7485b51c0ed192878fa1d2f948fb529ae1842cc5086c4b67f7be5b2039de9489",
             "63ecefee431d49523bc1136c4e72d0206a477086caf606cd5cf025686c109cf8"),
        "leaked-EM_OV_TLS_CA_G3C-by-emSign_G3":
            ("cb6e15165ac802e9b3f993f16c25d41f4e81c21ebde71ae1b012ac00bf9c7c3f",
             "63ecefee431d49523bc1136c4e72d0206a477086caf606cd5cf025686c109cf8"),
        "parent-emSign_Root_CS_CA_G3-by-emSign_ECC_Root_CA_G3":
            ("7137fa71ad46ba686f746d1014ac57e8e6c6e9af4aa2f73c0c44a5cf27debb59",
             "0a6c2b2ca5b364207954171987ac9d2178561569d8205457e77ca90c32ede282"),
        "parent-emSign_Root_TLS_CA_G3-by-emSign_ECC_Root_CA_G3":
            ("3094025792039a68af6e553686410bdab7c0d4a36b9084cba64202e35d6ebbdd",
             "c619e4780ed8e0abeda24ad732567de4383a7ea941338f6d1a7d1b49ac792fe9"),
        "root-AAA_Certificate_Services":
            ("d7a7a0fb5d7e2731d771e9484ebcdef71d5f0c3e0a2948782bc83ee0ea699ef4",
             "bd153ed7b0434f6886b17bce8bbe84ed340c7132d702a8f4fa318f756ecbd6f3"),
        "root-GTS_Root_R4":
            ("349dfa4058c5e263123b398ae795573c4e1313c83fe68f93556cd5e8031b3c7d",
             "9847e5653e5e9e847516e5cb818606aa7544a19be67fd7366d506988e8d84347"),
        "root-GlobalSign_Root_CA":
            ("ebd41040e4bb3ec742c9e381d31ef2a41a48b6685c96e7cef3c1df6cd4331c99",
             "2bcee858158cf5465fc9d76f0dfa312fef25a4dca8501da9b46b67d1fbfa1b64"),
        "root-ISRG_Root_X1":
            ("96bcec06264976f37460779acf28c5a7cfe8a3c0aae11a8ffcee05c0bddf08c6",
             "0b9fa5a59eed715c26c1020c711b4f6ec42d58b0015e14337a39dad301c5afc3"),
        "root-ISRG_Root_X2":
            ("69729b8e15a86efc177a57afb7171dfc64add28c2fca8cf1507e34453ccb1470",
             "762195c225586ee6c0237456e2107dc54f1efc21f61a792ebd515913cce68332"),
        "root-emSign_ECC_Root_CA_G3":
            ("86a1ecba089c4a8d3bbe2734c612ba341d813e043cf9e8a862cd5c57a36bbe6b",
             "8d417db2dd8bf5e3084d1e3f196d583849d81bdd4c00c70b9d39369e96b8c782"),
        "root-emSign_Root_CA_G1":
            ("40f6af0346a99aa1cd1d555a4e9cce62c7f9634603ee406615833dc8c8d00367",
             "376a1a7082a593dccc20d561d119e9ab8d30f11cc321d0a37fa41f0df284e01c"),
    ]

    /// Each path, whether it is accepted, and its certificates, leaf first.
    private let paths: [(id: String, accepted: Bool, certificates: [String])] = [
        ("R1", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_DV_TLS_CA_G3B-by-AAA",
                       "root-AAA_Certificate_Services"]),
        ("R2", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_DV_TLS_CA_G3B-by-emSign_G3",
                       "parent-emSign_Root_TLS_CA_G3-by-emSign_ECC_Root_CA_G3", "root-emSign_ECC_Root_CA_G3"]),
        ("R3", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_DV_TLS_CA_G3B-by-emSign_G3-ecdsa-twin"]),
        ("R4", false, ["accept-gts-1-leaf-pingolindev.com", "parent-emSign_Root_TLS_CA_G3-by-emSign_ECC_Root_CA_G3",
                       "root-emSign_ECC_Root_CA_G3"]),
        ("R5", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_OV_CS_CA_G3C-by-AAA",
                       "root-AAA_Certificate_Services"]),
        ("A1", true, ["accept-gts-1-leaf-pingolindev.com", "accept-gts-2-WE1", "root-GTS_Root_R4"]),
        ("A2", true, ["accept-gts-1-leaf-pingolindev.com", "accept-gts-2-WE1",
                      "accept-gts-3-GTS_Root_R4-by-GlobalSign_Root_CA", "root-GlobalSign_Root_CA"]),
        ("A3", true, ["accept-le-x1-1-leaf-valid-isrgrootx1.letsencrypt.org", "accept-le-x1-2-YR2",
                      "accept-le-x1-3-Root_YR-by-ISRG_Root_X1", "root-ISRG_Root_X1"]),
        ("A4", true, ["accept-le-x2-1-leaf-valid-isrgrootx2.letsencrypt.org", "accept-le-x2-2-YE1",
                      "accept-le-x2-3-Root_YE-by-ISRG_Root_X2", "root-ISRG_Root_X2"]),
        ("A5", true, ["accept-sectigo-1-leaf-sectigo.com",
                      "accept-sectigo-2-Sectigo_Public_Server_Authentication_CA_OV_R36",
                      "accept-sectigo-3-Sectigo_R46-by-USERTrust_RSA",
                      "accept-sectigo-4-USERTrust_RSA_Certification_Authority"]),
        ("A6", true, ["accept-gts-1-leaf-pingolindev.com", "accept-SSL.com_TLS_Transit_ECC_CA_R2-by-AAA",
                      "root-AAA_Certificate_Services"]),
        ("A7", true, ["accept-sectigo-1-leaf-sectigo.com",
                      "accept-sectigo-2-Sectigo_Public_Server_Authentication_CA_OV_R36",
                      "accept-sectigo-3-Sectigo_R46-by-USERTrust_RSA",
                      "accept-USERTrust_RSA_Certification_Authority-by-AAA", "root-AAA_Certificate_Services"]),
        ("A8", true, ["accept-gts-1-leaf-pingolindev.com", "accept-emSign_SSL_CA_G1-by-emSign_Root_CA_G1",
                      "root-emSign_Root_CA_G1"]),
        ("L1", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_DV_TLS_CA_G3B-by-AAA"]),
        ("L2", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_DV_TLS_CA_G3B-by-emSign_G3-ecdsa-twin"]),
        ("L3", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_DV_TLS_CA_G3B-by-emSign_G3"]),
        ("L4", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_DV_TLS_CA_G3C-by-AAA"]),
        ("L5", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_DV_TLS_CA_G3C-by-emSign_G3"]),
        ("L6", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_EV_TLS_CA_G3B-by-AAA"]),
        ("L7", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_EV_TLS_CA_G3B-by-emSign_G3"]),
        ("L8", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_EV_TLS_CA_G3C-by-AAA"]),
        ("L9", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_EV_TLS_CA_G3C-by-emSign_G3"]),
        ("L10", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_OV_CS_CA_G3B-by-AAA"]),
        ("L11", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_OV_CS_CA_G3B-by-emSign_G3"]),
        ("L12", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_OV_CS_CA_G3C-by-AAA"]),
        ("L13", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_OV_CS_CA_G3C-by-emSign_G3"]),
        ("L14", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_OV_TLS_CA_G3B-by-AAA"]),
        ("L15", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_OV_TLS_CA_G3B-by-emSign_G3"]),
        ("L16", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_OV_TLS_CA_G3C-by-AAA"]),
        ("L17", false, ["accept-gts-1-leaf-pingolindev.com", "leaked-EM_OV_TLS_CA_G3C-by-emSign_G3"]),
    ]

    private func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Each file is the listed certificate (its fingerprint, so no other certificate over the same key can stand
    /// in for it, as the ECDSA twin would), and it is read to the key listed for it.
    func testEveryCertificateIsTheContractsAndIsReadToTheKeyItLists() throws {
        XCTAssertEqual(files.count, 49)
        for (name, expected) in files.sorted(by: { $0.key < $1.key }) {
            let der = SecCertificateCopyData(try certificate(name)) as Data
            XCTAssertEqual(hex(SHA256.hash(data: der)), expected.certificate, "\(name): the certificate")
            let key = try XCTUnwrap(TrustBlocklist.subjectPublicKeyInfo(in: der), name)
            XCTAssertEqual(hex(SHA256.hash(data: key)), expected.key, "\(name): its key")
        }
    }

    func testEveryPathGetsTheContractsVerdict() throws {
        XCTAssertEqual(paths.count, 30)
        for path in paths {
            let chain = try path.certificates.map(certificate)
            XCTAssertEqual(TrustBlocklist.accepts(evaluated: true, chain: chain), path.accepted, path.id)
        }
    }
}
