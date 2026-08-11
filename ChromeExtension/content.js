(function () {
  const BRIDGE = "http://127.0.0.1:47873";
  const POLL_INTERVAL_MS = 500;
  const STEP_SETTLE_MS = 450;
  const MAX_NEXT_STEPS = 2;
  const SCRIPT_REVISION = "frontlink-20260711-r5";
  const RELOAD_MESSAGE_TYPE = "sms-code-bridge.reload-extension";
  const LOCAL_MOCK_PATHS = [
    "/frontlink-mock-suite.html",
    "/source-mock-suite.html",
    "/revision-mock-suite.html"
  ];
  let lastHandledSessionID = null;

  document.documentElement.setAttribute("data-sms-code-dom-bridge", "loaded");
  document.documentElement.setAttribute("data-sms-code-dom-bridge-version", SCRIPT_REVISION);

  function sleep(milliseconds) {
    return new Promise((resolve) => setTimeout(resolve, milliseconds));
  }

  function isVisible(element) {
    if (!element || !(element instanceof Element)) return false;
    const view = element.ownerDocument?.defaultView || window;
    const style = view.getComputedStyle(element);
    if (style.display === "none" || style.visibility === "hidden" || Number(style.opacity) === 0) {
      return false;
    }
    const rect = element.getBoundingClientRect();
    return rect.width > 4 && rect.height > 4 && rect.bottom >= 0 && rect.right >= 0;
  }

  function textOf(element) {
    if (!element) return "";
    return [
      element.innerText,
      element.textContent,
      element.getAttribute?.("aria-label"),
      element.getAttribute?.("title"),
      element.getAttribute?.("placeholder"),
      element.getAttribute?.("name"),
      element.getAttribute?.("id"),
      element.getAttribute?.("class")
    ]
      .filter(Boolean)
      .join(" ")
      .replace(/\s+/g, " ")
      .trim();
  }

  function uniqueElements(elements) {
    return Array.from(new Set(elements));
  }

  function rootsFor(container) {
    return uniqueElements([container, document.body].filter(Boolean));
  }

  function elementsInRoots(roots, selector) {
    return uniqueElements(roots.flatMap((root) => Array.from(root.querySelectorAll(selector))));
  }

  function dispatchInput(element, value) {
    const previous = element.value;
    element.focus();
    element.value = value;
    const tracker = element._valueTracker;
    if (tracker) tracker.setValue(previous);
    element.dispatchEvent(new InputEvent("input", { bubbles: true, inputType: "insertText", data: value }));
    element.dispatchEvent(new Event("change", { bubbles: true }));
  }

  function scorePhoneField(input) {
    if (!isVisible(input) || input.disabled || input.readOnly) return -999;
    const type = (input.getAttribute("type") || "text").toLowerCase();
    if (["password", "hidden", "checkbox", "radio", "submit", "button"].includes(type)) return -999;

    const text = textOf(input).toLowerCase();
    const placeholder = (input.getAttribute("placeholder") || "").trim();
    if (/验证码|校验码|动态码|verification|otp|verify.?code|sms.?code|sms.?verify/.test(text)) {
      return -999;
    }
    if (
      /^\+?\d{1,4}$/.test(placeholder)
      || /region[-_ ]?code|country[-_ ]?code|area[-_ ]?code|区号|国家地区/.test(text)
    ) {
      return -999;
    }

    let score = 0;
    if (document.activeElement === input) score += 100;
    if (type === "tel") score += 45;
    if (/手机|手机号|电话|mobile|phone|tel/.test(text)) score += 75;
    if (/账号|帐号|account|login|user/.test(text)) score += 20;
    if (/搜索|search|评论|comment|地址|url|邮箱|email/.test(text)) score -= 120;
    const rect = input.getBoundingClientRect();
    if (rect.width > 520) score -= 30;
    if ((input.value || "").trim().length > 0) score -= 10;
    return score;
  }

  function findPhoneField() {
    const candidates = Array.from(document.querySelectorAll("input, textarea"))
      .map((input) => ({ input, score: scorePhoneField(input) }))
      .filter((item) => item.score > 0)
      .sort((a, b) => b.score - a.score);
    return candidates[0]?.input || null;
  }

  function scoreEmailField(input) {
    if (!isVisible(input) || input.disabled || input.readOnly) return -999;
    const type = (input.getAttribute("type") || "text").toLowerCase();
    if (["password", "hidden", "checkbox", "radio", "submit", "button", "tel"].includes(type)) return -999;
    const text = textOf(input).toLowerCase();
    if (/验证码|校验码|动态码|verification|otp|phone|mobile|手机号|搜索|search/.test(text)) return -999;
    let score = document.activeElement === input ? 100 : 0;
    if (type === "email") score += 80;
    if (input.getAttribute("autocomplete") === "email") score += 70;
    if (/邮箱|email|e-mail|账号|account|login/.test(text)) score += 55;
    return score;
  }

  function findEmailField() {
    return Array.from(document.querySelectorAll("input, textarea"))
      .map((input) => ({ input, score: scoreEmailField(input) }))
      .filter((item) => item.score > 0)
      .sort((a, b) => b.score - a.score)[0]?.input || null;
  }

  function closestLoginContainer(anchor) {
    let current = anchor;
    while (current && current !== document.body) {
      const role = current.getAttribute?.("role") || "";
      const text = textOf(current);
      const tag = current.tagName;
      const classOrID = `${current.className || ""} ${current.id || ""}`;
      const isStructuralContainer = ["DIV", "SECTION", "MAIN", "ARTICLE", "ASIDE"].includes(tag);
      if (
        tag === "FORM" ||
        role === "dialog" ||
        (isStructuralContainer && /modal|dialog|signin|passport/.test(classOrID)) ||
        (isStructuralContainer
          && /手机|手机号|phone|mobile|验证码|code|otp|登录|login/i.test(text)
          && /获取验证码|发送验证码|发送短信|下一步|继续|登录|send code|get code|sign in/i.test(text))
      ) {
        return current;
      }
      current = current.parentElement;
    }
    return document.body;
  }

  function currentLoginContainer(phoneField) {
    const activeContainer = closestLoginContainer(document.activeElement);
    if (activeContainer !== document.body && activeContainer.isConnected && isVisible(activeContainer)) {
      return activeContainer;
    }

    const candidates = Array.from(document.querySelectorAll("form, [role='dialog']"))
      .filter((element) => isVisible(element))
      .map((element) => {
        const text = textOf(element).toLowerCase();
        let score = 0;
        if (element.contains(phoneField)) score += 100;
        if (/手机|手机号|phone|mobile|验证码|code|otp|登录|login/.test(text)) score += 40;
        if (/获取验证码|发送验证码|send code|get code/.test(text)) score += 25;
        return { element, score };
      })
      .sort((left, right) => right.score - left.score);
    return candidates[0]?.element || document.body;
  }

  function clickElement(element) {
    if (!element || !isVisible(element)) return false;
    element.scrollIntoView({ block: "center", inline: "center" });
    element.click();
    return true;
  }

  function isAgreementText(text) {
    return /同意|已阅读|协议|隐私|terms|privacy|agreement/i.test(text)
      && !/第三方|授权登录|marketing|remember|记住登录/i.test(text);
  }

  function linkedLabelFor(input) {
    const parentLabel = input.closest?.("label");
    if (parentLabel) return parentLabel;

    if (!input.id) return null;
    return Array.from(document.querySelectorAll("label"))
      .find((label) => label.htmlFor === input.id) || null;
  }

  function agreementCandidateFor(element) {
    const tag = element.tagName;
    let control = element;
    let activationTarget = element;

    if (tag === "LABEL") {
      control = element.querySelector("input[type='checkbox'], [role='checkbox']")
        || (element.htmlFor ? document.getElementById(element.htmlFor) : null);
      activationTarget = element;
    } else if (tag === "INPUT" && element.type === "checkbox") {
      activationTarget = linkedLabelFor(element) || element;
    }

    const agreementText = [
      element,
      activationTarget,
      control,
      control?.parentElement,
      control?.parentElement?.parentElement
    ]
      .filter(Boolean)
      .map(textOf)
      .join(" ");
    if (!control || !isVisible(activationTarget) || !isAgreementText(agreementText)) return null;
    const isCheckbox = control.matches?.("input[type='checkbox'], [role='checkbox']");
    if (!isCheckbox) return null;
    const checked = Boolean(control.checked) || control.getAttribute("aria-checked") === "true";
    return { control, activationTarget, checked };
  }

  function findAgreement(container) {
    const selector = "input[type='checkbox'], [role='checkbox'], label";
    const candidates = elementsInRoots(rootsFor(container), selector)
      .map(agreementCandidateFor)
      .filter(Boolean);
    return candidates.find((candidate) => !candidate.checked) || null;
  }

  function checkAgreement(container) {
    const agreement = findAgreement(container);
    if (!agreement) return false;
    clickElement(agreement.activationTarget);
    return Boolean(agreement.control.checked) || agreement.control.getAttribute("aria-checked") === "true";
  }

  function candidateText(element) {
    return textOf(element).toLowerCase();
  }

  function isDisabledLike(element, text) {
    return element.disabled
      || element.getAttribute("aria-disabled") === "true"
      || /倒计时|后重发|已发送|重新发送|重发|resend|sent|\d+\s*(s|秒)/i.test(text);
  }

  function actionElements(container) {
    const selector = [
      "button",
      "a",
      "input[type='submit']",
      "input[type='button']",
      "[role='button']",
      "[role='link']",
      "[tabindex]",
      "span",
      "div"
    ].join(",");
    return elementsInRoots(rootsFor(container), selector)
      .filter(isVisible)
      .filter((element) => {
        const tag = element.tagName;
        if (tag !== "DIV" && tag !== "SPAN") return true;
        return !Array.from(element.querySelectorAll("button, a, [role='button'], input[type='submit']"))
          .some((child) => isVisible(child));
      });
  }

  function isRequestCodeText(text) {
    return /获取验证码|发送验证码|获取短信验证码|发送短信验证码|获取校验码|发送校验码|获取动态码|发送动态码|发送短信|send code|get code|send sms|get sms code|verification code/i.test(text);
  }

  function findRequestButton(container) {
    const candidates = actionElements(container)
      .map((element) => ({ element, text: candidateText(element) }))
      .filter(({ element, text }) => isRequestCodeText(text) && !isDisabledLike(element, text))
      .sort((a, b) => {
        const aRect = a.element.getBoundingClientRect();
        const bRect = b.element.getBoundingClientRect();
        return (aRect.width * aRect.height) - (bRect.width * bRect.height);
      });
    return candidates[0]?.element || null;
  }

  function isNextStepText(text) {
    if (!text) return false;
    if (/登录|注册|发送|获取|验证码|协议|隐私|第三方|密码|扫码|重发|resend|send code|get code/i.test(text)) {
      return false;
    }
    return /下一步|继续|继续操作|next|continue/i.test(text);
  }

  function findNextStepButton(container, skippedElements) {
    const candidates = actionElements(container)
      .map((element) => ({ element, text: candidateText(element) }))
      .filter(({ element, text }) => isNextStepText(text) && !isDisabledLike(element, text))
      .filter(({ element }) => !skippedElements.has(element))
      .sort((a, b) => {
        const aRect = a.element.getBoundingClientRect();
        const bRect = b.element.getBoundingClientRect();
        return (aRect.width * aRect.height) - (bRect.width * bRect.height);
      });
    return candidates[0]?.element || null;
  }

  function findVerificationField(container, phoneField) {
    const inputs = elementsInRoots(rootsFor(container), "input, textarea")
      .filter((input) => input !== phoneField)
      .filter((input) => isVisible(input) && !input.disabled && !input.readOnly)
      .filter((input) => {
        const text = textOf(input).toLowerCase();
        const type = (input.getAttribute("type") || "text").toLowerCase();
        const maxLength = Number(input.getAttribute("maxlength") || input.maxLength || 0);
        return type !== "password"
          && (/验证码|校验码|动态码|code|otp|sms|verification/i.test(text) || (maxLength > 0 && maxLength <= 8));
      });
    return inputs[0] || null;
  }

  function findVerificationFieldForCode() {
    const active = document.activeElement;
    if (active && ["INPUT", "TEXTAREA"].includes(active.tagName) && isVisible(active)) {
      const activeText = textOf(active).toLowerCase();
      const activeType = (active.getAttribute("type") || "text").toLowerCase();
      const maxLength = Number(active.getAttribute("maxlength") || active.maxLength || 0);
      if (activeType !== "password"
        && (/验证码|校验码|动态码|code|otp|sms|verification/i.test(activeText) || (maxLength > 0 && maxLength <= 8))) {
        return active;
      }
    }

    return findVerificationField(document.body, null);
  }

  function otpGroupFor(field, code) {
    const container = closestLoginContainer(field);
    const inputs = Array.from(container.querySelectorAll("input"))
      .filter((input) => isVisible(input) && !input.disabled && !input.readOnly)
      .filter((input) => {
        const type = (input.getAttribute("type") || "text").toLowerCase();
        const maxLength = Number(input.getAttribute("maxlength") || input.maxLength || 0);
        return type !== "password" && maxLength === 1;
      });

    if (inputs.length >= code.length) return inputs.slice(0, code.length);
    return [];
  }

  function fillVerificationCode(code) {
    const field = findVerificationFieldForCode();
    if (!field) return { filled: false, field: null };

    const maxLength = Number(field.getAttribute("maxlength") || field.maxLength || 0);
    if (maxLength === 1 && code.length > 1) {
      const group = otpGroupFor(field, code);
      if (group.length >= code.length) {
        Array.from(code).forEach((character, index) => dispatchInput(group[index], character));
        group[Math.min(code.length - 1, group.length - 1)].focus();
        return { filled: true, field };
      }
    }

    dispatchInput(field, code);
    return { filled: (field.value || "") === code, field };
  }

  function isLoginSubmitText(text) {
    if (!text) return false;
    if (/微信|qq|微博|apple|google|github|扫码|二维码|密码登录|短信登录|其他方式|其它方式|第三方|获取验证码|发送验证码|重发|resend|send code|get code/i.test(text)) {
      return false;
    }
    return /登录|登陆|登入|注册|完成|确认|提交|log in|login|sign in|continue|next/i.test(text);
  }

  function findLoginSubmit(container) {
    const candidates = actionElements(container)
      .map((element) => ({ element, text: candidateText(element) }))
      .filter(({ element, text }) => isLoginSubmitText(text) && !isDisabledLike(element, text))
      .sort((a, b) => {
        const aRect = a.element.getBoundingClientRect();
        const bRect = b.element.getBoundingClientRect();
        const aPrimary = /登录|登陆|login|sign in/i.test(a.text) ? 0 : 1;
        const bPrimary = /登录|登陆|login|sign in/i.test(b.text) ? 0 : 1;
        if (aPrimary !== bPrimary) return aPrimary - bPrimary;
        return (aRect.width * aRect.height) - (bRect.width * bRect.height);
      });
    return candidates[0]?.element || null;
  }

  function humanVerificationReason(container) {
    const selector = [
      "iframe[src*='captcha' i]",
      "iframe[src*='recaptcha' i]",
      "[class*='captcha' i]",
      "[class*='geetest' i]",
      "[class*='hcaptcha' i]",
      "[class*='turnstile' i]",
      "[id*='captcha' i]",
      "[id*='geetest' i]"
    ].join(",");
    if (elementsInRoots(rootsFor(container), selector).some(isVisible)) {
      return "检测到人机验证组件，请手动完成后继续";
    }

    const text = textOf(container || document.body).toLowerCase();
    if (/人机验证|安全验证|请完成验证|完成验证|滑块|拖动|点击文字|verify you are human|i am not a robot/.test(text)) {
      return "检测到人机验证提示，请手动完成后继续";
    }
    return null;
  }

  function hasVisibleIframe() {
    return Array.from(document.querySelectorAll("iframe")).some(isVisible);
  }

  function createResult(command) {
    return {
      sessionID: command.sessionID,
      commandType: command.type,
      status: "failed",
      message: "",
      filledPhone: false,
      checkedAgreement: false,
      clickedNextStep: false,
      clickedRequest: false,
      focusedVerification: false,
      manualInterventionRequired: false,
      filledCode: false,
      clickedLogin: false
    };
  }

  function markManualIntervention(result, message) {
    result.status = "manual";
    result.manualInterventionRequired = true;
    result.message = message;
    return result;
  }

  async function report(result) {
    try {
      await fetch(`${BRIDGE}/result`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify(result)
      });
    } catch (_) {
      // 本地 App 可能已退出，忽略上报失败。
    }
  }

  async function handleCommand(command) {
    if (command.type === "fillCode") return handleFillCodeCommand(command);
    if (command.type === "reloadExtension") return handleReloadExtensionCommand(command);
    if (command.type === "emailLogin") return handleEmailLoginCommand(command);
    return handlePhoneLoginCommand(command);
  }

  function handleReloadExtensionCommand(command) {
    const result = createResult(command);
    result.status = "ok";
    result.message = "扩展正在重新加载";
    return result;
  }

  async function requestExtensionReload() {
    // 内容脚本不能直接调用 reload，必须把生命周期操作交给扩展 Service Worker。
    const response = await chrome.runtime.sendMessage({ type: RELOAD_MESSAGE_TYPE });
    if (!response?.ok) {
      throw new Error(response?.error || "扩展后台未接受重载命令");
    }
  }

  async function handlePhoneLoginCommand(command) {
    return handleAccountLoginCommand(command, findPhoneField, "未找到手机号输入框");
  }

  async function handleEmailLoginCommand(command) {
    return handleAccountLoginCommand(command, findEmailField, "未找到邮箱输入框");
  }

  async function handleAccountLoginCommand(command, findField, missingFieldMessage) {
    const result = createResult(command);

    try {
      const phoneField = findField();
      if (hasVisibleIframe()) {
          return markManualIntervention(result, "登录表单位于嵌入页面，请手动进入后继续");
        }
      if (!phoneField) {
        result.message = missingFieldMessage;
        return result;
      }

      dispatchInput(phoneField, command.phoneNumber);
      result.filledPhone = true;
      await sleep(220);

      const clickedNextElements = new Set();
      for (let round = 0; round <= MAX_NEXT_STEPS; round += 1) {
        const container = currentLoginContainer(phoneField);
        const verificationWarning = humanVerificationReason(container);
        if (verificationWarning) return markManualIntervention(result, verificationWarning);

        if (checkAgreement(container)) {
          result.checkedAgreement = true;
          await sleep(160);
        }

        const requestButton = findRequestButton(container);
        if (requestButton) {
          result.clickedRequest = clickElement(requestButton);
          if (!result.clickedRequest) {
            result.message = "点击发送验证码失败";
            return result;
          }

          await sleep(STEP_SETTLE_MS);
          const afterRequestWarning = humanVerificationReason(closestLoginContainer(requestButton));
          if (afterRequestWarning) return markManualIntervention(result, afterRequestWarning);

          const verificationField = findVerificationField(document.body, phoneField);
          if (verificationField) {
            verificationField.focus();
            result.focusedVerification = document.activeElement === verificationField;
          }
          result.status = "ok";
          result.message = "已点击发送验证码";
          return result;
        }

        const nextStep = findNextStepButton(container, clickedNextElements);
        if (!nextStep || round === MAX_NEXT_STEPS) {
          result.message = result.clickedNextStep
            ? "下一步后未找到发送验证码按钮"
            : "未找到发送验证码或下一步按钮";
          return result;
        }

        clickedNextElements.add(nextStep);
        result.clickedNextStep = clickElement(nextStep) || result.clickedNextStep;
        if (!result.clickedNextStep) {
          result.message = "点击下一步失败";
          return result;
        }
        await sleep(STEP_SETTLE_MS);
      }

      result.message = "前半链路未完成";
      return result;
    } catch (error) {
      result.message = error instanceof Error ? error.message : String(error);
      return result;
    }
  }

  async function handleFillCodeCommand(command) {
    const result = createResult(command);

    try {
      const code = String(command.verificationCode || "").trim();
      if (!code) {
        result.message = "验证码为空";
        return result;
      }

      const filled = fillVerificationCode(code);
      result.filledCode = filled.filled;
      result.focusedVerification = Boolean(filled.field && document.activeElement === filled.field);
      if (!result.filledCode) {
        result.message = "未找到或未填入验证码框";
        return result;
      }

      if (command.autoSubmit) {
        await sleep(220);
        const container = closestLoginContainer(filled.field || document.body);
        const verificationWarning = humanVerificationReason(container);
        if (verificationWarning) {
          result.status = "manual";
          result.manualInterventionRequired = true;
          result.message = `已填验证码，${verificationWarning}`;
          return result;
        }
        result.clickedLogin = clickElement(findLoginSubmit(container));
      }

      result.status = "ok";
      result.message = result.clickedLogin ? "已填验证码并点击登录" : "已填验证码";
      return result;
    } catch (error) {
      result.message = error instanceof Error ? error.message : String(error);
      return result;
    }
  }

  function isLocalMockSuite() {
    return ["127.0.0.1", "localhost"].includes(location.hostname)
      && LOCAL_MOCK_PATHS.some((path) => location.pathname.endsWith(path));
  }

  function installLocalMockAPI() {
    if (!isLocalMockSuite()) return false;

    window.SmsCodeDomBridgeTest = Object.freeze({
      revision: SCRIPT_REVISION,
      handleCommand: async (command) => {
        if (!String(command?.sessionID || "").startsWith("local-mock-")) {
          throw new Error("无效本地 mock 命令");
        }
        return handleCommand(command);
      }
    });
    return true;
  }

  async function poll() {
    try {
      const visible = document.visibilityState === "visible" ? "1" : "0";
      const response = await fetch(`${BRIDGE}/command?host=${encodeURIComponent(location.host)}&visible=${visible}`, {
        cache: "no-store"
      });
      const payload = await response.json();
      const command = payload && payload.command;
      if (!command || command.sessionID === lastHandledSessionID) return;

      lastHandledSessionID = command.sessionID;
      const result = await handleCommand(command);
      await report(result);
      if (command.type === "reloadExtension" && result.status === "ok") {
        await requestExtensionReload();
      }
    } catch (_) {
      // App 没启动或桥接端口暂不可用时保持静默轮询。
    }
  }

  const isLocalMock = installLocalMockAPI();
  if (window.top === window && !isLocalMock) {
    setInterval(poll, POLL_INTERVAL_MS);
    poll();
  }
})();
